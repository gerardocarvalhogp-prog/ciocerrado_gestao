-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Tres defeitos encontrados em teste manual ponta a ponta, 24-25/08/2026.
--
-- Nenhum e de seguranca — os tres sao de comportamento, com dinheiro ou
-- dado envolvido, por isso ficaram para decisao explicita antes de
-- mexer. Corrigidos agora, um de cada vez, com o motivo.
-- =====================================================================

set search_path = gestao, public;


-- ---------------------------------------------------------------------
-- 1. FATURA EM DUPLICIDADE
--
-- `_recalcular_fatura_participante` roda toda vez que o rooming muda.
-- Ela procurava a fatura 'estimada' e, se a unica que existia ja
-- estava 'emitida' ou 'paga' (ou seja, nao e mais 'estimada'), o
-- `select ... into v_fatura` vinha NULL e a funcao criava uma fatura
-- NOVA, com o valor cheio recalculado — nao a diferenca.
--
-- Medido: Carlos tinha uma fatura paga de R$ 1.500. Removi um item do
-- rooming (o servico caiu para R$ 1.100) e chamei o recalculo. Resultado:
-- a fatura paga ficou intacta em R$ 1.500 (correto — emitir congela o
-- valor), mas uma SEGUNDA fatura 'estimada' de R$ 1.100 nasceu do lado.
-- R$ 2.600 cobrados sobre R$ 1.100 de servico.
--
-- O CONSERTO: se ja existe fatura 'emitida' ou 'paga', o recalculo para
-- ali e devolve o valor congelado, sem tocar em nada. Isso e a mesma
-- regra que ja vale para toda a tela de Financeiro ("emitir congela o
-- valor") — so que agora o recalculo automatico obedece tambem.
--
-- Cobranca adicional depois de emitido (ex.: participante troca de
-- quarto depois de pago) passa a exigir acao manual do admin na aba
-- Financeiro, nao mais um valor fantasma criado sozinho.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION "gestao"."_recalcular_fatura_participante"("p_participante_id" "uuid") RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid; v_res uuid; v_fatura uuid;
  v_total numeric(12,2) := 0; v_linha record;
  v_transfers int; v_pt numeric(12,2);
  v_travada numeric(12,2);
begin
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
      -- "Criança" com valores diferentes e nao entende
      v_desc := case when v_linha.item = 'crianca' then 'Criança' else 'Acompanhante adulto' end
              || case when v_linha.idade is not null
                      then ' · ' || v_linha.idade || ' anos' else '' end;

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
                                 then ' · ' || v_linha.idade || ' anos' else '' end,
              v_linha.qtd, v_pt);
      v_total := v_total + v_linha.qtd * v_pt;
    end if;
  end loop;

  update faturas set total = v_total where id = v_fatura;
  return v_total;
end;
$$;


-- Mesmo padrao, do lado do patrocinador (quarto extra + transfer).
CREATE OR REPLACE FUNCTION "gestao"."_recalcular_fatura_patrocinador"("p_patrocinador_id" "uuid") RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid; v_fatura uuid; v_total numeric(12,2) := 0;
  v_linha record; v_pt numeric(12,2);
  v_travada numeric(12,2);
begin
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

  update faturas set total = v_total where id = v_fatura;

  if v_total = 0 then
    delete from fatura_itens where fatura_id = v_fatura;
    delete from faturas where id = v_fatura;
  end if;

  return v_total;
end;
$$;


-- ---------------------------------------------------------------------
-- 2. REGRA DE INDICACAO AUSENTE NA MESA REDONDA
--
-- A primeira camada da regra de alocacao (CLAUDE.md): "se o patrocinador
-- indicou a pessoa no PERFIL, ela vai para a mesa dele". Em producao,
-- `patro_convidados_disponiveis` ordenava so por `empresa, nome` — a
-- indicacao nao pesava em nada, e a coluna que o portal.html ja LE
-- (`c.indicado_por_mim`, portal.html:794, o selo "indicado por voce")
-- nem existia no retorno da funcao. O selo nunca apareceu em producao.
--
-- Muda o formato de retorno (nova coluna), entao precisa DROP antes do
-- CREATE — Postgres nao deixa `CREATE OR REPLACE` alterar as colunas de
-- um RETURNS TABLE.
-- ---------------------------------------------------------------------

DROP FUNCTION IF EXISTS "gestao"."patro_convidados_disponiveis"("uuid");

CREATE FUNCTION "gestao"."patro_convidados_disponiveis"("p_sessao_id" "uuid")
RETURNS TABLE("participante_id" "uuid", "nome" "text", "empresa" "text", "cargo" "text", "segmento" "text", "indicado_por_mim" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_patro uuid; v_evento uuid; v_tipo text;
begin
  select s.patrocinador_id, s.evento_id, s.tipo
    into v_patro, v_evento, v_tipo
  from sessoes s where s.id = p_sessao_id;

  perform _exige_patrocinador(v_patro);

  return query
    select pa.id, g.nome, g.empresa, g.cargo, g.segmento,
           -- coalesce e obrigatorio: para quem ninguem indicou a coluna
           -- e nula, e "null = uuid" da NULL, nao false. Em ORDER BY
           -- DESC o Postgres poe NULL primeiro — sem o coalesce, os NAO
           -- indicados subiam acima dos indicados, invertendo a regra.
           coalesce(pa.indicado_por_patrocinador_id = v_patro, false) as indicado_por_mim
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
    order by
      coalesce(pa.indicado_por_patrocinador_id = v_patro, false) desc,
      g.empresa, g.nome;
end;
$$;

-- DROP FUNCTION apaga os grants junto, e funcao nova nasce com EXECUTE
-- implicito para PUBLIC (regra do proprio Postgres, nao do schema) —
-- e anon herda por ali. E o mesmo problema que a trava de anon corrigiu
-- em toda funcao existente; aqui teria voltado por baixo, numa funcao
-- nova, se eu confiasse no default privilege. Repete o padrao explicito
-- que o resto do arquivo ja usa (ver admin_aprovar_participante).
REVOKE ALL ON FUNCTION "gestao"."patro_convidados_disponiveis"("uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_convidados_disponiveis"("uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."patro_convidados_disponiveis"("uuid") TO "service_role";

-- confere aqui em vez de confiar.
do $$
begin
  if not has_function_privilege('authenticated',
       'gestao.patro_convidados_disponiveis(uuid)', 'EXECUTE') then
    raise exception 'authenticated sem execute em patro_convidados_disponiveis apos recriar';
  end if;
  if has_function_privilege('anon',
       'gestao.patro_convidados_disponiveis(uuid)', 'EXECUTE') then
    raise exception 'anon com execute em patro_convidados_disponiveis apos recriar';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 3. IMPORTADOR DE GESTORES ACEITA E-MAIL INVALIDO
--
-- `admin_importar_gestores` rejeitava linha com nome ou e-mail vazio,
-- mas nao validava formato. Testado: "nao-e-email" virava gestor
-- cadastrado. Sem @ e dominio, o magic link nunca chega — vira cadastro
-- morto que ninguem nota ate perguntar por que a pessoa nao respondeu.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION "gestao"."admin_importar_gestores"("p_linhas" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_item jsonb;
  v_id uuid; v_empresa_ant text; v_cargo_ant text; v_empresa_nova text;
  v_criados int := 0; v_atualizados int := 0; v_erros int := 0;
  v_sugeridos int := 0;
  v_erros_det jsonb := '[]'::jsonb;
  v_imp uuid; v_linha int := 0;
begin
  perform _exige_admin();

  insert into importacoes (tipo, total_linhas, executado_por)
  values ('gestores', jsonb_array_length(coalesce(p_linhas,'[]'::jsonb)),
          auth.jwt() ->> 'email')
  returning id into v_imp;

  for v_item in select * from jsonb_array_elements(coalesce(p_linhas,'[]'::jsonb))
  loop
    v_linha := v_linha + 1;

    if coalesce(trim(v_item ->> 'email'),'') = ''
       or coalesce(trim(v_item ->> 'nome'),'') = '' then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'motivo', 'nome ou e-mail vazio',
        'nome', v_item ->> 'nome');
      continue;
    end if;

    -- endereco mal formado vira cadastro que nunca recebe magic link,
    -- e ninguem descobre ate perguntar por que a pessoa nao respondeu
    if trim(v_item ->> 'email') !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'motivo', 'e-mail invalido: ' || (v_item ->> 'email'),
        'nome', v_item ->> 'nome');
      continue;
    end if;

    select g.id, g.empresa, g.cargo into v_id, v_empresa_ant, v_cargo_ant
    from gestores g where g.email_norm = norm_doc(v_item ->> 'email');

    if v_id is null then
      insert into gestores (nome, email, empresa, cargo, telefone, cnpj,
                            segmento, estado, perfil, origem,
                            posicao_gestor, cidade, faturamento, funcionarios)
      values (trim(v_item ->> 'nome'), lower(trim(v_item ->> 'email')),
              nullif(v_item ->> 'empresa',''), nullif(v_item ->> 'cargo',''),
              nullif(v_item ->> 'telefone',''), nullif(v_item ->> 'cnpj',''),
              nullif(v_item ->> 'segmento',''), nullif(v_item ->> 'estado',''),
              nullif(v_item ->> 'perfil',''), 'importacao',
              nullif(v_item ->> 'posicao',''), nullif(v_item ->> 'cidade',''),
              nullif(v_item ->> 'faturamento',''), nullif(v_item ->> 'funcionarios',''));
      v_criados := v_criados + 1;
      continue;
    end if;

    v_empresa_nova := nullif(trim(v_item ->> 'empresa'), '');

    if v_empresa_nova is not null
       and coalesce(trim(v_empresa_ant),'') <> ''
       and lower(unaccent('unaccent', v_empresa_ant))
           <> lower(unaccent('unaccent', v_empresa_nova)) then

      insert into sugestoes_ia (tipo, gestor_id, campo, valor_atual,
                                valor_sugerido, confianca, fonte,
                                justificativa, status)
      select 'troca_empresa', v_id, 'empresa', v_empresa_ant,
             v_empresa_nova, 100, 'importacao de planilha',
             'Linha ' || v_linha || ' da planilha traz empresa diferente da cadastrada',
             'pendente'
      where not exists (
        select 1 from sugestoes_ia s
        where s.gestor_id = v_id and s.campo = 'empresa'
          and s.valor_sugerido = v_empresa_nova and s.status = 'pendente');

      v_sugeridos := v_sugeridos + 1;
    end if;

    if nullif(v_item ->> 'cargo','') is not null
       and lower(coalesce(v_cargo_ant,'')) <> lower(v_item ->> 'cargo') then
      insert into gestores_historico (gestor_id, campo, valor_antigo,
                                      valor_novo, detectado_por)
      values (v_id, 'cargo', v_cargo_ant, v_item ->> 'cargo', 'importacao');
    end if;

    update gestores set
      nome     = coalesce(nullif(v_item ->> 'nome',''), nome),
      empresa  = case when coalesce(trim(empresa),'') = ''
                      then coalesce(v_empresa_nova, empresa) else empresa end,
      cargo    = coalesce(nullif(v_item ->> 'cargo',''), cargo),
      telefone = coalesce(nullif(v_item ->> 'telefone',''), telefone),
      cnpj     = coalesce(nullif(v_item ->> 'cnpj',''), cnpj),
      segmento = coalesce(nullif(v_item ->> 'segmento',''), segmento),
      estado   = coalesce(nullif(v_item ->> 'estado',''), estado),
      perfil   = coalesce(nullif(v_item ->> 'perfil',''), perfil),
      posicao_gestor = coalesce(nullif(v_item ->> 'posicao',''), posicao_gestor),
      cidade   = coalesce(nullif(v_item ->> 'cidade',''), cidade),
      faturamento  = coalesce(nullif(v_item ->> 'faturamento',''), faturamento),
      funcionarios = coalesce(nullif(v_item ->> 'funcionarios',''), funcionarios)
    where id = v_id;

    v_atualizados := v_atualizados + 1;
  end loop;

  update importacoes set criados = v_criados, atualizados = v_atualizados,
                         erros = v_erros
   where id = v_imp;

  return jsonb_build_object('ok', true, 'criados', v_criados,
    'atualizados', v_atualizados, 'erros', v_erros,
    'sugestoes', v_sugeridos, 'detalhe_erros', v_erros_det);
end;
$$;
