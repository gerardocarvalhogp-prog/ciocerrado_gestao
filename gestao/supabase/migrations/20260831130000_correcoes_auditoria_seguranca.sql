-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Correcoes da auditoria de seguranca de 30/08/2026 (achado critico +
-- 3 achados medios). Nao mexe no schema public (sistema de massagem).
--
-- Achado critico: 4 funcoes internas SECURITY DEFINER (_garantir_reserva,
-- _recalcular_fatura_participante, _recalcular_fatura_patrocinador,
-- _recalcular_fechado) tinham EXECUTE liberado pra authenticated sem
-- nenhuma checagem de dono no corpo -- qualquer usuario logado, mesmo
-- um CIO comum, conseguia ler/gravar fatura e fila de qualquer outro
-- patrocinador. Corrige nas duas camadas: revoga o EXECUTE (nenhuma
-- delas precisa ser chamada direto pelo cliente -- confirmado que todo
-- caminho legitimo passa por outra funcao SECURITY DEFINER de dono
-- postgres, que ignora GRANT ao chamar) e adiciona a checagem que falta,
-- usando os helpers que ja existem e ja passam staff/dono (mesmo padrao
-- do resto do schema). Verificado, um a um, que todo caller interno hoje
-- ja passa o proprio id ou ja e staff -- nao quebra nenhum fluxo:
--   admin_recalcular_faturas -> _exige_admin() antes (staff passa)
--   part_calcular_fatura     -> usa _meu_participante() (proprio id)
--   part_salvar_rooming      -> usa _meu_participante() (proprio id)
--   patro_salvar_brinde      -> ja chama _exige_patrocinador() antes
--   patro_salvar_quarto      -> ja chama _exige_patrocinador() antes
--
-- Achado medio (informacional): _reserva_da_indicacao, _janelas_da_fila
-- e _escolha_em_aberto revelavam timing de fila/reserva de qualquer
-- patrocinador. Sao helpers puramente internos (so chamados por outras
-- SECURITY DEFINER de dono postgres -- _escolha_em_aberto chama
-- _janelas_da_fila, _reserva_da_indicacao chama _escolha_em_aberto,
-- patro_minha_vez e patro_escolher_convidados chamam ambas): revogar o
-- EXECUTE de authenticated basta, sem precisar de checagem de dono no
-- corpo (nao ha "dono" natural pra essas tres -- operam sobre a fila
-- inteira do evento por desenho).
--
-- Achado medio: v_pendencias e v_pendencias_fatos (migracao
-- 20260830140000) ficaram sem security_invoker=true -- CREATE OR
-- REPLACE VIEW reseta essa opcao em silencio. Hoje sem risco real (zero
-- grant pra anon/authenticated nelas), mas e a mesma armadilha que ja
-- pegou este projeto duas vezes antes.
--
-- De brinde: norm_cpf/norm_doc tambem sem search_path fixo -- as duas
-- unicas funcoes do schema gestao nessa situacao (todas as SECURITY
-- DEFINER ja tinham; confirmado por consulta a pg_proc antes de
-- escrever esta migracao). Nao mexe no restante dos 259 avisos do
-- Security Advisor -- a maioria e do schema public, fora do escopo.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- Achado critico: revoga + adiciona checagem de dono
-- ---------------------------------------------------------------------

create or replace function gestao._garantir_reserva(p_participante_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare v_res uuid; v_evento uuid;
begin
  perform _exige_participante(p_participante_id);

  select id into v_res from reservas
   where participante_id = p_participante_id and status <> 'cancelado';

  if v_res is not null then return v_res; end if;

  select evento_id into v_evento from participantes where id = p_participante_id;

  insert into reservas (evento_id, participante_id, rotulo, tipo, origem, status)
  values (v_evento, p_participante_id, 'Hospedagem', 'duplo', 'inscricao', 'rascunho')
  returning id into v_res;

  return v_res;
end;
$function$;

create or replace function gestao._recalcular_fatura_participante(p_participante_id uuid)
 returns numeric
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare
  v_evento uuid; v_res uuid; v_fatura uuid;
  v_total numeric(12,2) := 0; v_linha record;
  v_pt numeric(12,2); v_travada numeric(12,2);
begin
  perform _exige_participante(p_participante_id);

  select evento_id into v_evento from participantes where id = p_participante_id;
  if v_evento is null then return 0; end if;

  select id into v_res from reservas
   where participante_id = p_participante_id and status <> 'cancelado';
  if v_res is null then return 0; end if;

  -- emitida/paga esta congelada: recalculo automatico para aqui.
  select total into v_travada from faturas
   where participante_id = p_participante_id and status in ('emitida','paga');
  if v_travada is not null then
    return v_travada;
  end if;

  select id into v_fatura from faturas
   where participante_id = p_participante_id and status = 'estimada';

  if v_fatura is null then
    insert into faturas (evento_id, participante_id, status)
    values (v_evento, p_participante_id, 'estimada')
    returning id into v_fatura;
  else
    delete from fatura_itens where fatura_id = v_fatura;
  end if;

  for v_linha in
    with base as (
      select o.id,
             _item_do_ocupante(o.tipo) as item,
             _idade_no_evento(v_evento, o.data_nascimento) as idade
      from ocupantes o
      where o.reserva_id = v_res and o.tipo <> 'titular'
    ),
    marcado as (
      select b.*,
             b.item = 'acompanhante_adulto'
               and row_number() over (
                     partition by b.item
                     order by _preco_item(v_evento, b.item, b.idade) desc, b.id
                   ) <= _cortesia_acompanhante() as cortesia
      from base b
    )
    select item, idade, cortesia, count(*) as qtd
    from marcado
    group by 1, 2, 3
  loop
    declare
      v_valor numeric(12,2) := _preco_item(v_evento, v_linha.item, v_linha.idade);
      v_desc text;
    begin
      -- descricao carrega a idade: sem isso o cliente ve duas linhas
      -- "Criança" com valores diferentes e nao entende
      v_desc := case when v_linha.item = 'crianca' then 'Criança' else 'Acompanhante adulto' end
              || case when v_linha.idade is not null
                      then ' · ' || v_linha.idade || ' anos' else '' end;

      if v_linha.cortesia then
        -- linha visivel de proposito, com zero: o cliente precisa ver
        -- que ganhou, senao conta as pessoas e acha que faltou uma
        insert into fatura_itens (fatura_id, reserva_id, descricao,
                                  quantidade, valor_unit)
        values (v_fatura, v_res, v_desc || ' · cortesia', v_linha.qtd, 0);
      elsif v_valor > 0 then
        insert into fatura_itens (fatura_id, reserva_id, descricao,
                                  quantidade, valor_unit)
        values (v_fatura, v_res, v_desc, v_linha.qtd, v_valor);
        v_total := v_total + v_linha.qtd * v_valor;
      end if;
    end;
  end loop;

  -- transfer tambem pode ter faixa (crianca de colo nao paga)
  for v_linha in
    select _idade_no_evento(v_evento, o.data_nascimento) as idade,
           count(*) as qtd
    from ocupantes o
    where o.reserva_id = v_res and o.usa_transfer
    group by 1
  loop
    v_pt := _preco_item(v_evento, 'transfer', v_linha.idade);
    if v_pt > 0 then
      insert into fatura_itens (fatura_id, reserva_id, descricao,
                                quantidade, valor_unit)
      values (v_fatura, v_res,
              'Transfer' || case when v_linha.idade is not null
                                 then ' · ' || v_linha.idade || ' anos' else '' end,
              v_linha.qtd, v_pt);
      v_total := v_total + v_linha.qtd * v_pt;
    end if;
  end loop;

  update faturas set total = v_total where id = v_fatura;
  return v_total;
end;
$function$;

create or replace function gestao._recalcular_fatura_patrocinador(p_patrocinador_id uuid)
 returns numeric
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare
  v_evento uuid; v_fatura uuid; v_total numeric(12,2) := 0;
  v_linha record; v_pt numeric(12,2);
  v_travada numeric(12,2);
begin
  perform _exige_patrocinador(p_patrocinador_id);

  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;
  if v_evento is null then return 0; end if;

  -- emitida/paga esta congelada: recalculo automatico para aqui.
  select total into v_travada from faturas
   where patrocinador_id = p_patrocinador_id and status in ('emitida','paga');
  if v_travada is not null then
    return v_travada;
  end if;

  select id into v_fatura from faturas
   where patrocinador_id = p_patrocinador_id and status = 'estimada';

  if v_fatura is null then
    insert into faturas (evento_id, patrocinador_id, status)
    values (v_evento, p_patrocinador_id, 'estimada')
    returning id into v_fatura;
  else
    delete from fatura_itens where fatura_id = v_fatura;
  end if;

  for v_linha in
    select r.tipo, count(*) as qtd
    from reservas r
    where r.patrocinador_id = p_patrocinador_id
      and r.origem = 'extra' and r.status <> 'cancelado'
    group by r.tipo
  loop
    declare v_v numeric(12,2) := _preco_item(v_evento, 'quarto_' || v_linha.tipo);
    begin
      if v_v > 0 then
        insert into fatura_itens (fatura_id, descricao, quantidade, valor_unit)
        values (v_fatura, 'Quarto extra ' || v_linha.tipo, v_linha.qtd, v_v);
        v_total := v_total + v_linha.qtd * v_v;
      end if;
    end;
  end loop;

  for v_linha in
    select _idade_no_evento(v_evento, o.data_nascimento) as idade,
           count(*) as qtd
    from ocupantes o
    join reservas r on r.id = o.reserva_id and r.status <> 'cancelado'
    where r.patrocinador_id = p_patrocinador_id and o.usa_transfer
    group by 1
  loop
    v_pt := _preco_item(v_evento, 'transfer', v_linha.idade);
    if v_pt > 0 then
      insert into fatura_itens (fatura_id, descricao, quantidade, valor_unit)
      values (v_fatura, 'Transfer', v_linha.qtd, v_pt);
      v_total := v_total + v_linha.qtd * v_pt;
    end if;
  end loop;

  -- Entrega no quarto e servico do resort, cobrado por porta: e
  -- camareira subindo com caixa. No stand nao ha custo — o brinde fica
  -- na mesa e quem quer, pega.
  if exists (select 1 from brindes b
              where b.patrocinador_id = p_patrocinador_id
                and b.vai_enviar and b.destino = 'quarto') then
    declare
      v_quartos int;
      v_ve numeric(12,2) := _preco_item(v_evento, 'entrega_brinde_quarto');
    begin
      select count(*) into v_quartos from reservas r
       where r.patrocinador_id = p_patrocinador_id and r.status <> 'cancelado';
      if v_ve > 0 and v_quartos > 0 then
        insert into fatura_itens (fatura_id, descricao, quantidade, valor_unit)
        values (v_fatura, 'Entrega de brinde no quarto', v_quartos, v_ve);
        v_total := v_total + v_quartos * v_ve;
      end if;
    end;
  end if;

  update faturas set total = v_total where id = v_fatura;

  if v_total = 0 then
    delete from fatura_itens where fatura_id = v_fatura;
    delete from faturas where id = v_fatura;
  end if;

  return v_total;
end;
$function$;

create or replace function gestao._recalcular_fechado(p_patrocinador_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare v_pend int;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  select count(*) into v_pend
  from reservas
  where patrocinador_id = p_patrocinador_id
    and status = 'rascunho';

  if v_pend = 0 then
    update patrocinadores
       set fechado_em = coalesce(fechado_em, now())
     where id = p_patrocinador_id
       and exists (select 1 from reservas r
                   where r.patrocinador_id = p_patrocinador_id
                     and r.status = 'completo');
  end if;
end;
$function$;

revoke execute on function gestao._garantir_reserva(uuid) from public, authenticated;
revoke execute on function gestao._recalcular_fatura_participante(uuid) from public, authenticated;
revoke execute on function gestao._recalcular_fatura_patrocinador(uuid) from public, authenticated;
revoke execute on function gestao._recalcular_fechado(uuid) from public, authenticated;

-- ---------------------------------------------------------------------
-- Achado medio: vazamento informacional -- so revoga (helpers puramente
-- internos, sem "dono" natural: operam sobre a fila inteira do evento)
-- ---------------------------------------------------------------------

revoke execute on function gestao._reserva_da_indicacao(uuid, text) from public, authenticated;
revoke execute on function gestao._janelas_da_fila(uuid, text) from public, authenticated;
revoke execute on function gestao._escolha_em_aberto(uuid) from public, authenticated;

-- ---------------------------------------------------------------------
-- Achado medio: security_invoker resetado em silencio pelo CREATE OR
-- REPLACE VIEW da migracao 20260830140000
-- ---------------------------------------------------------------------

alter view gestao.v_pendencias set (security_invoker = true);
alter view gestao.v_pendencias_fatos set (security_invoker = true);

-- ---------------------------------------------------------------------
-- De brinde: search_path fixo nas 2 funcoes do schema gestao que
-- ficaram sem (as unicas -- todas as SECURITY DEFINER ja tinham)
-- ---------------------------------------------------------------------

alter function gestao.norm_cpf(text) set search_path = 'gestao', 'public';
alter function gestao.norm_doc(text) set search_path = 'gestao', 'public';
