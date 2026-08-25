-- =====================================================================
-- ESTADO ANTERIOR DO REMOTO  ·  dump de 24/08/2026, antes de aplicar
-- 02-fatura-complementar.sql e 03-indicacao-e-porte.sql.
--
-- Rollback: rodar este arquivo devolve as tres funcoes ao que estavam.
-- Para a patro_convidados_disponiveis e preciso dropar antes, porque o
-- retorno volta a ter 5 colunas:
--
--   drop function if exists gestao.patro_convidados_disponiveis(uuid);
--
-- Nao editar: e dump, nao fonte.
-- =====================================================================

CREATE OR REPLACE FUNCTION gestao._recalcular_fatura_participante(p_participante_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_evento uuid; v_res uuid; v_fatura uuid;
  v_total numeric(12,2) := 0; v_linha record;
  v_transfers int; v_pt numeric(12,2);
begin
  select evento_id into v_evento from participantes where id = p_participante_id;
  if v_evento is null then return 0; end if;

  select id into v_res from reservas
   where participante_id = p_participante_id and status <> 'cancelado';
  if v_res is null then return 0; end if;

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
    select _item_do_ocupante(o.tipo) as item,
           _idade_no_evento(v_evento, o.data_nascimento) as idade,
           count(*) as qtd
    from ocupantes o
    where o.reserva_id = v_res and o.tipo <> 'titular'
    group by 1, 2
  loop
    declare
      v_valor numeric(12,2) := _preco_item(v_evento, v_linha.item, v_linha.idade);
      v_desc text;
    begin
      -- descricao carrega a idade: sem isso o cliente ve duas linhas
      -- "CrianÃ§a" com valores diferentes e nao entende
      v_desc := case when v_linha.item = 'crianca' then 'CrianÃ§a' else 'Acompanhante adulto' end
              || case when v_linha.idade is not null
                      then ' Â· ' || v_linha.idade || ' anos' else '' end;

      if v_valor > 0 then
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
                                 then ' Â· ' || v_linha.idade || ' anos' else '' end,
              v_linha.qtd, v_pt);
      v_total := v_total + v_linha.qtd * v_pt;
    end if;
  end loop;

  update faturas set total = v_total where id = v_fatura;
  return v_total;
end;
$function$;

CREATE OR REPLACE FUNCTION gestao._recalcular_fatura_patrocinador(p_patrocinador_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_evento uuid; v_fatura uuid; v_total numeric(12,2) := 0;
  v_linha record; v_pt numeric(12,2);
begin
  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;
  if v_evento is null then return 0; end if;

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

  update faturas set total = v_total where id = v_fatura;

  if v_total = 0 then
    delete from fatura_itens where fatura_id = v_fatura;
    delete from faturas where id = v_fatura;
  end if;

  return v_total;
end;
$function$;

CREATE OR REPLACE FUNCTION gestao.patro_convidados_disponiveis(p_sessao_id uuid)
 RETURNS TABLE(participante_id uuid, nome text, empresa text, cargo text, segmento text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v_patro uuid; v_evento uuid; v_tipo text;
begin
  select s.patrocinador_id, s.evento_id, s.tipo
    into v_patro, v_evento, v_tipo
  from sessoes s where s.id = p_sessao_id;

  perform _exige_patrocinador(v_patro);

  return query
    select pa.id, g.nome, g.empresa, g.cargo, g.segmento
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    where pa.evento_id = v_evento
      and pa.status = 'aprovado'
      and not exists (
        select 1 from sessao_convidados sc
        join sessoes s3 on s3.id = sc.sessao_id
        where sc.participante_id = pa.id
          and sc.status = 'confirmado'
          and s3.evento_id = v_evento
          and s3.tipo = v_tipo)
    order by g.empresa, g.nome;
end;
$function$;

