-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- BASELINE · dump do schema `gestao` do projeto hospedado, 24/08/2026.
--
-- POR QUE ESTE ARQUIVO EXISTE
--
-- Ate aqui havia DUAS implementacoes do mesmo sistema. As 25 migrations
-- escritas a mao (agora em `supabase/migrations-antigas/`) montavam um
-- banco parecido com o hospedado, mas nao igual: 33 funcoes locais
-- chamavam `exigir_admin`, `evento_id_por_slug` e `cap_tipo`, helpers
-- que o hospedado nem tem — la a mesma checagem e `_exige_admin`. Onze
-- funcoes existiam so de um lado.
--
-- O custo disso era cobrado em toda mudanca: cada correcao precisava ser
-- escrita duas vezes, uma como migration e outra como arquivo em
-- `supabase/remoto/`, e o `db reset` testava um sistema que nao era o
-- que estava no ar.
--
-- O hospedado virou a origem porque e ele que atende o front em
-- producao. A unica coisa em que a linhagem local estava na frente —
-- `checkin_desfazer` com autor e com erro quando nao desfaz nada — foi
-- promovida antes, por `supabase/remoto/06`, e ja esta neste dump.
--
-- COMO USAR DAQUI PARA A FRENTE
--
--   supabase db reset                 reproduz o hospedado do zero
--   ... escreve a migration nova ...
--   supabase db push                  aplica no hospedado
--
-- `supabase/remoto/` deixa de ser o caminho de correcao. O historico de
-- migrations do hospedado foi marcado como aplicado ate este baseline,
-- entao o `db push` so leva o que vier depois.
--
-- NAO EDITE ESTE ARQUIVO. E dump. Mudanca entra como migration nova.
--
-- Os comentarios de dentro dos corpos das funcoes sobreviveram; os
-- cabecalhos que explicavam cada decisao estao em
-- `supabase/migrations-antigas/` e no historico do git.
-- =====================================================================




SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);

-- ACRESCENTADO A MAO (unica linha que nao veio do pg_dump).
--
-- A linha acima e do proprio dump e zera o search_path. Com ele vazio,
-- criar a tabela `admins` quebra: a coluna gerada `email_norm` chama
-- `gestao.norm_doc`, que por sua vez chama `unaccent(...)` sem
-- qualificar, e `unaccent` mora no schema public.
--
-- Nao da para consertar do outro lado sem risco: `norm_doc` alimenta
-- colunas GENERATED de tres tabelas, e a forma de dois argumentos
-- resolve tambem o DICIONARIO pelo search_path. No hospedado isso nunca
-- aparece porque search_path nunca esta vazio na pratica.
SELECT pg_catalog.set_config('search_path', 'public', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "gestao";


ALTER SCHEMA "gestao" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_escolha_em_aberto"("p_sessao_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  select s.passou_em is null
     and s.escolha_encerrada_em is null
     and (select count(*) from sessao_convidados sc
           where sc.sessao_id = s.id and sc.status = 'confirmado') < s.vagas
     and (j.fim is null or now() < j.fim)
  from sessoes s
  join patrocinadores p on p.id = s.patrocinador_id
  left join lateral _janelas_da_fila(s.evento_id, s.tipo) j
         on j.cota_id = p.cota_id
  where s.id = p_sessao_id;
$$;


ALTER FUNCTION "gestao"."_escolha_em_aberto"("p_sessao_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_exige_admin"() RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'Acesso restrito a administradores' using errcode = '42501';
  end if;
end;
$$;


ALTER FUNCTION "gestao"."_exige_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_exige_participante"("p_participante_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  if is_staff() then return; end if;

  if not exists (
    select 1 from participantes pa
    join gestores g on g.id = pa.gestor_id
    where pa.id = p_participante_id
      and g.email_norm = norm_doc(auth.jwt() ->> 'email')
  ) then
    raise exception 'Sem acesso a esta inscricao' using errcode = '42501';
  end if;
end;
$$;


ALTER FUNCTION "gestao"."_exige_participante"("p_participante_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_exige_patrocinador"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  if not pode_ver_patrocinador(p_id) then
    raise exception 'Sem acesso a este patrocinador'
      using errcode = '42501';
  end if;
end;
$$;


ALTER FUNCTION "gestao"."_exige_patrocinador"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_exige_staff"() RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  if not is_staff() then
    raise exception 'Acesso restrito a equipe' using errcode = '42501';
  end if;
end;
$$;


ALTER FUNCTION "gestao"."_exige_staff"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_fim_da_janela"("p_inicio" timestamp with time zone, "p_horas" integer, "p_prazo" "date", "p_fechou" timestamp with time zone, "p_sem_sessao" boolean) RETURNS timestamp with time zone
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    -- cota que nao tem mesa deste tipo nao tem o que esperar
    when p_sem_sessao then p_inicio
    else least(
      case when p_inicio is not null and p_horas is not null
           then p_inicio + make_interval(hours => p_horas) end,
      -- o teto e o FIM do dia informado, nao o comeco dele
      case when p_prazo is not null then (p_prazo + 1)::timestamptz end,
      p_fechou)
  end;
$$;


ALTER FUNCTION "gestao"."_fim_da_janela"("p_inicio" timestamp with time zone, "p_horas" integer, "p_prazo" "date", "p_fechou" timestamp with time zone, "p_sem_sessao" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_garantir_reserva"("p_participante_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_res uuid; v_evento uuid;
begin
  select id into v_res from reservas
   where participante_id = p_participante_id and status <> 'cancelado';

  if v_res is not null then return v_res; end if;

  select evento_id into v_evento from participantes where id = p_participante_id;

  insert into reservas (evento_id, participante_id, rotulo, tipo, origem, status)
  values (v_evento, p_participante_id, 'Hospedagem', 'duplo', 'inscricao', 'rascunho')
  returning id into v_res;

  return v_res;
end;
$$;


ALTER FUNCTION "gestao"."_garantir_reserva"("p_participante_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_idade_no_evento"("p_evento" "uuid", "p_nascimento" "date") RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  select case
    when p_nascimento is null then null
    else extract(year from age(
      coalesce((select data_inicio from eventos where id = p_evento), current_date),
      p_nascimento))::int
  end;
$$;


ALTER FUNCTION "gestao"."_idade_no_evento"("p_evento" "uuid", "p_nascimento" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_intencao"("v" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when v is null or trim(v) = '' then null
    when lower(unaccent('unaccent', v)) like '%aumentar%'  then 'aumentar'
    when lower(unaccent('unaccent', v)) like '%diminuir%'  then 'diminuir'
    when lower(unaccent('unaccent', v)) like '%estudo%'    then 'estudo'
    when lower(unaccent('unaccent', v)) like '%sem previsao%' then 'sem_previsao'
    else 'outro'
  end;
$$;


ALTER FUNCTION "gestao"."_intencao"("v" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_item_do_ocupante"("p_tipo" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case when p_tipo = 'crianca' then 'crianca'
              else 'acompanhante_adulto' end;
$$;


ALTER FUNCTION "gestao"."_item_do_ocupante"("p_tipo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_janelas_da_fila"("p_evento" "uuid", "p_tipo" "text") RETURNS TABLE("cota_id" "uuid", "ordem" integer, "inicio" timestamp with time zone, "fim" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  with recursive base as (
    select c.id,
           c.ordem_prioridade,
           row_number() over (order by c.ordem_prioridade, c.nome) as n,
           c.janela_horas,
           c.prazo_indicacao,
           (select count(s.id) = 0
              from patrocinadores p
              left join sessoes s on s.patrocinador_id = p.id
                                 and s.evento_id = p_evento
                                 and s.tipo = p_tipo
             where p.cota_id = c.id and p.status = 'ativo') as sem_sessao,
           -- so ha "fechou" quando TODAS as sessoes da cota fecharam;
           -- enquanto uma estiver escolhendo, a cota nao fechou
           (select case
                     when count(*) filter (where s.escolha_encerrada_em is null
                                             and s.passou_em is null) > 0
                       then null
                     else max(coalesce(s.escolha_encerrada_em, s.passou_em))
                   end
              from patrocinadores p
              join sessoes s on s.patrocinador_id = p.id
                            and s.evento_id = p_evento
                            and s.tipo = p_tipo
             where p.cota_id = c.id and p.status = 'ativo') as fechou_em
    from cotas c
    where c.evento_id = p_evento
  ),
  cadeia as (
    select b.id, b.ordem_prioridade::int as ordem, b.n,
           e.escolha_abre_em as inicio,
           _fim_da_janela(e.escolha_abre_em, b.janela_horas,
                          b.prazo_indicacao, b.fechou_em, b.sem_sessao) as fim
    from base b
    cross join (select escolha_abre_em from eventos where id = p_evento) e
    where b.n = 1
    union all
    select b.id, b.ordem_prioridade::int, b.n,
           c.fim,
           _fim_da_janela(c.fim, b.janela_horas,
                          b.prazo_indicacao, b.fechou_em, b.sem_sessao)
    from cadeia c
    join base b on b.n = c.n + 1
  )
  select id, ordem, inicio, fim from cadeia;
$$;


ALTER FUNCTION "gestao"."_janelas_da_fila"("p_evento" "uuid", "p_tipo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_meu_participante"("p_evento_slug" "text") RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  select pa.id
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  join eventos  e on e.id = pa.evento_id
  where e.slug = p_evento_slug
    and g.email_norm = norm_doc(auth.jwt() ->> 'email')
    and pa.status <> 'cancelado'
  limit 1;
$$;


ALTER FUNCTION "gestao"."_meu_participante"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_porte_faturamento"("p_texto" "text") RETURNS numeric
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case when p_texto is null or btrim(p_texto) = '' then 0 else
    -- pega TODOS os pares numero+unidade e fica com o maior: numa faixa
    -- como "De 500 Milhões a 1,1 Bilhões" o que ordena e o teto.
    coalesce((
      select max(replace(m[1], ',', '.')::numeric
                 * case when m[2] = 'bilh' then 1000 else 1 end)
      from regexp_matches(lower(p_texto),
             '([0-9]+(?:[.,][0-9]+)?)\s*(bilh|milh)', 'g') as m
    ), 0)
    -- "Acima de 5 Bilhões" e "De 3,1 a 5 Bilhões" tem o mesmo teto; a
    -- faixa aberta e a maior das duas e precisa desempatar para cima.
    + case when lower(p_texto) like 'acima%' then 1 else 0 end
  end;
$$;


ALTER FUNCTION "gestao"."_porte_faturamento"("p_texto" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "gestao"."_porte_faturamento"("p_texto" "text") IS 'Faixa de faturamento escrita (Sympla) -> teto em milhoes, para ordenar por porte.';



CREATE OR REPLACE FUNCTION "gestao"."_preco_item"("p_evento" "uuid", "p_item" "text", "p_idade" integer DEFAULT NULL::integer) RETURNS numeric
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  select coalesce(
    (select pr.valor from precos pr
      where pr.evento_id = p_evento and pr.item = p_item
        and p_idade is not null
        and coalesce(pr.idade_min, 0)   <= p_idade
        and coalesce(pr.idade_max, 999) >= p_idade
      -- faixa mais especifica ganha da generica
      order by (pr.idade_min is not null) desc, pr.idade_min desc
      limit 1),
    (select pr.valor from precos pr
      where pr.evento_id = p_evento and pr.item = p_item
        and pr.idade_min is null and pr.idade_max is null
      limit 1),
    0);
$$;


ALTER FUNCTION "gestao"."_preco_item"("p_evento" "uuid", "p_item" "text", "p_idade" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_rank_cargo"("v" "text") RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when v is null then 9
    when upper(unaccent('unaccent', v)) ~ '(CIO|CTO|CHIEF|DIRETOR|DIRECTOR|PRESIDENTE|VP|VICE)' then 1
    when upper(unaccent('unaccent', v)) ~ '(SUPERINTENDENTE|HEAD)' then 2
    when upper(unaccent('unaccent', v)) ~ '(GERENTE|MANAGER)'      then 3
    when upper(unaccent('unaccent', v)) ~ '(COORDENADOR|COORD)'    then 4
    when upper(unaccent('unaccent', v)) ~ '(SUPERVISOR)'           then 5
    when upper(unaccent('unaccent', v)) ~ '(ANALISTA|ESPECIALISTA)' then 6
    else 9
  end;
$$;


ALTER FUNCTION "gestao"."_rank_cargo"("v" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_rank_pos"("v" "text") RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when v is null then 2
    when v like '%1%' then 0
    when v like '%2%' then 1
    else 2
  end;
$$;


ALTER FUNCTION "gestao"."_rank_pos"("v" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_recalcular_fatura_participante"("p_participante_id" "uuid") RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid; v_res uuid; v_fatura uuid;
  v_total numeric(12,2) := 0; v_linha record;
  v_transfers int; v_pt numeric(12,2);
  v_ja numeric(12,2) := 0;
begin
  select evento_id into v_evento from participantes where id = p_participante_id;
  if v_evento is null then return 0; end if;

  select id into v_res from reservas
   where participante_id = p_participante_id and status <> 'cancelado';
  if v_res is null then return 0; end if;

  -- O que ja foi congelado. Emitida e paga entram as duas porque a
  -- propria cobranca complementar vira documento quando for emitida —
  -- na rodada seguinte ela conta aqui e a soma continua fechando.
  select coalesce(sum(total), 0) into v_ja
    from faturas
   where participante_id = p_participante_id
     and status in ('emitida','paga');

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

  -- A linha de abatimento fica visivel de proposito: o participante
  -- precisa ver a conta cheia e o que ja pagou, senao a complementar
  -- chega como um valor solto que ninguem sabe explicar.
  if v_ja <> 0 then
    insert into fatura_itens (fatura_id, reserva_id, descricao,
                              quantidade, valor_unit)
    values (v_fatura, v_res, 'Já faturado anteriormente', 1, -v_ja);
    v_total := v_total - v_ja;
  end if;

  update faturas set total = v_total where id = v_fatura;
  return v_total;
end;
$$;


ALTER FUNCTION "gestao"."_recalcular_fatura_participante"("p_participante_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_recalcular_fatura_patrocinador"("p_patrocinador_id" "uuid") RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid; v_fatura uuid; v_total numeric(12,2) := 0;
  v_linha record; v_pt numeric(12,2);
  v_ja numeric(12,2) := 0;
begin
  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;
  if v_evento is null then return 0; end if;

  select coalesce(sum(total), 0) into v_ja
    from faturas
   where patrocinador_id = p_patrocinador_id
     and status in ('emitida','paga');

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

  if v_ja <> 0 then
    insert into fatura_itens (fatura_id, descricao, quantidade, valor_unit)
    values (v_fatura, 'Já faturado anteriormente', 1, -v_ja);
    v_total := v_total - v_ja;
  end if;

  update faturas set total = v_total where id = v_fatura;

  if v_total = 0 then
    delete from fatura_itens where fatura_id = v_fatura;
    delete from faturas where id = v_fatura;
  end if;

  return v_total;
end;
$$;


ALTER FUNCTION "gestao"."_recalcular_fatura_patrocinador"("p_patrocinador_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_recalcular_fechado"("p_patrocinador_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_pend int;
begin
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
$$;


ALTER FUNCTION "gestao"."_recalcular_fechado"("p_patrocinador_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_reserva_da_indicacao"("p_participante_id" "uuid", "p_tipo" "text") RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  select pa.indicado_por_patrocinador_id
  from participantes pa
  where pa.id = p_participante_id
    and pa.indicado_por_patrocinador_id is not null
    and exists (
      select 1 from sessoes s
      where s.patrocinador_id = pa.indicado_por_patrocinador_id
        and s.evento_id = pa.evento_id
        and s.tipo = p_tipo
        and _escolha_em_aberto(s.id)
    );
$$;


ALTER FUNCTION "gestao"."_reserva_da_indicacao"("p_participante_id" "uuid", "p_tipo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."_rotulo_faixa"("p_min" integer, "p_max" integer) RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when p_min is null and p_max is null then ''
    when p_min is null then ' (até ' || p_max || ' anos)'
    when p_max is null then ' (' || p_min || ' anos ou mais)'
    else ' (' || p_min || ' a ' || p_max || ' anos)'
  end;
$$;


ALTER FUNCTION "gestao"."_rotulo_faixa"("p_min" integer, "p_max" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_adicionar_convidado_sessao"("p_sessao_id" "uuid", "p_participante_id" "uuid", "p_aderencia" numeric DEFAULT NULL::numeric) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();

  insert into sessao_convidados (sessao_id, participante_id, origem, aderencia)
  values (p_sessao_id, p_participante_id, 'admin', p_aderencia)
  on conflict do nothing;

  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_adicionar_convidado_sessao"("p_sessao_id" "uuid", "p_participante_id" "uuid", "p_aderencia" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_alocar_quarto"("p_reserva_id" "uuid", "p_quarto_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_anterior uuid; v_ocupado uuid; v_cap int; v_qtd int; v_tipo text;
begin
  perform _exige_staff();

  select quarto_id into v_anterior from reservas where id = p_reserva_id;
  if not found then
    raise exception 'Reserva nao encontrada' using errcode = 'P0002';
  end if;

  if p_quarto_id is null then
    update reservas set quarto_id = null where id = p_reserva_id;
    update quartos set status = 'disponivel' where id = v_anterior;
    return jsonb_build_object('ok', true, 'liberado', true);
  end if;

  -- trava o quarto: dois admins alocando ao mesmo tempo nao podem
  -- colocar duas reservas no mesmo numero
  select q.capacidade, q.tipo into v_cap, v_tipo
  from quartos q where q.id = p_quarto_id for update;

  select r.id into v_ocupado from reservas r
   where r.quarto_id = p_quarto_id and r.status <> 'cancelado'
     and r.id <> p_reserva_id
   limit 1;

  if v_ocupado is not null then
    return jsonb_build_object('ok', false, 'motivo', 'quarto_ocupado');
  end if;

  select count(*) into v_qtd from ocupantes where reserva_id = p_reserva_id;

  if v_qtd > v_cap then
    return jsonb_build_object('ok', false, 'motivo', 'capacidade',
      'ocupantes', v_qtd, 'capacidade', v_cap);
  end if;

  update reservas set quarto_id = p_quarto_id where id = p_reserva_id;
  update quartos set status = 'reservado' where id = p_quarto_id;

  if v_anterior is not null and v_anterior <> p_quarto_id then
    update quartos set status = 'disponivel' where id = v_anterior;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_alocar_quarto"("p_reserva_id" "uuid", "p_quarto_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_aplicar_sugestao"("p_sugestao_id" "uuid", "p_aprovar" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_tipo text; v_gestor uuid; v_campo text;
  v_novo text; v_atual text; v_empresa text;
begin
  perform _exige_admin();

  select tipo, gestor_id, campo, valor_sugerido, valor_atual, empresa
    into v_tipo, v_gestor, v_campo, v_novo, v_atual, v_empresa
  from sugestoes_ia where id = p_sugestao_id and status = 'pendente';

  if v_tipo is null then
    raise exception 'Sugestao nao encontrada ou ja revisada'
      using errcode = 'P0002';
  end if;

  if not p_aprovar then
    update sugestoes_ia set status = 'ignorada',
           revisado_por = auth.jwt() ->> 'email', revisado_em = now()
     where id = p_sugestao_id;
    return jsonb_build_object('ok', true, 'aplicada', false);
  end if;

  if v_tipo = 'troca_empresa' then
    insert into gestores_historico (gestor_id, campo, valor_antigo,
                                    valor_novo, detectado_por)
    values (v_gestor, 'empresa', v_atual, v_novo, 'ia');

    update gestores set empresa = v_novo where id = v_gestor;

  elsif v_tipo = 'dado_divergente' and v_campo is not null then
    insert into gestores_historico (gestor_id, campo, valor_antigo,
                                    valor_novo, detectado_por)
    values (v_gestor, v_campo, v_atual, v_novo, 'ia');

    -- lista fechada de campos: evita SQL dinamico com nome de coluna
    -- vindo de fora do banco
    if v_campo = 'cargo' then
      update gestores set cargo = v_novo where id = v_gestor;
    elsif v_campo = 'telefone' then
      update gestores set telefone = v_novo where id = v_gestor;
    elsif v_campo = 'segmento' then
      update gestores set segmento = v_novo where id = v_gestor;
    elsif v_campo = 'cnpj' then
      update gestores set cnpj = v_novo where id = v_gestor;
    else
      raise exception 'Campo % nao pode ser atualizado por sugestao', v_campo
        using errcode = '22023';
    end if;

  elsif v_tipo in ('novo_gestor','nova_empresa') then
    -- nao cria cadastro sozinha: vira indicacao para o time trabalhar
    null;
  end if;

  update sugestoes_ia set status = 'aplicada',
         revisado_por = auth.jwt() ->> 'email', revisado_em = now()
   where id = p_sugestao_id;

  return jsonb_build_object('ok', true, 'aplicada', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_aplicar_sugestao"("p_sugestao_id" "uuid", "p_aprovar" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_aprovar_participante"("p_participante_id" "uuid", "p_aprovado" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_email text; v_evento uuid;
begin
  perform _exige_admin();

  update participantes set
    status      = case when p_aprovado then 'aprovado' else 'recusado' end,
    aprovado_em = now(),
    aprovado_por = auth.jwt() ->> 'email'
  where id = p_participante_id
  returning evento_id into v_evento;

  if v_evento is null then
    raise exception 'Participante nao encontrado' using errcode = 'P0002';
  end if;

  select g.email into v_email
  from participantes pa join gestores g on g.id = pa.gestor_id
  where pa.id = p_participante_id;

  -- aprovado entra na fila de contrato; o job do Autentique le daqui
  if p_aprovado then
    insert into contratos (participante_id, status)
    values (p_participante_id, 'nao_enviado')
    on conflict (participante_id) do nothing;

    insert into notificacoes (evento_id, destinatario, tipo, assunto)
    values (v_evento, v_email, 'inscricao_aprovada', 'Inscricao aprovada');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_aprovar_participante"("p_participante_id" "uuid", "p_aprovado" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_converter_indicacao"("p_indicacao_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid; v_gestor uuid; v_part uuid;
  v_nome text; v_email text; v_empresa text; v_cargo text;
  v_tel text; v_patro uuid;
begin
  perform _exige_admin();

  select evento_id, nome, email, empresa, cargo, telefone, patrocinador_id, gestor_id
    into v_evento, v_nome, v_email, v_empresa, v_cargo, v_tel, v_patro, v_gestor
  from indicacoes where id = p_indicacao_id;

  if v_evento is null then
    raise exception 'Indicacao nao encontrada' using errcode = 'P0002';
  end if;
  if coalesce(trim(v_email),'') = '' then
    raise exception 'Indicacao sem e-mail nao pode virar inscricao'
      using errcode = '22023';
  end if;

  if v_gestor is null then
    select id into v_gestor from gestores where email_norm = norm_doc(v_email);
  end if;

  if v_gestor is null then
    insert into gestores (nome, email, empresa, cargo, telefone, origem)
    values (v_nome, lower(trim(v_email)), v_empresa, v_cargo, v_tel, 'indicacao')
    returning id into v_gestor;
  end if;

  insert into participantes (evento_id, gestor_id, status, origem,
                             indicado_por_patrocinador_id)
  values (v_evento, v_gestor, 'pendente', 'indicacao', v_patro)
  on conflict (evento_id, gestor_id) do nothing
  returning id into v_part;

  update indicacoes set status = 'convidado', gestor_id = v_gestor
   where id = p_indicacao_id;

  return jsonb_build_object('ok', true, 'gestor_id', v_gestor,
                            'participante_id', v_part);
end;
$$;


ALTER FUNCTION "gestao"."admin_converter_indicacao"("p_indicacao_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_convidado_avulso"("p_sessao_id" "uuid", "p_nome" "text", "p_empresa" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text", "p_telefone" "text" DEFAULT NULL::"text", "p_cargo" "text" DEFAULT NULL::"text", "p_rotulo" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid; v_gestor uuid; v_part uuid;
  v_vagas int; v_ocupadas int; v_reaproveitado boolean := false;
begin
  perform _exige_staff();

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome' using errcode='22023';
  end if;

  select s.evento_id, s.vagas into v_evento, v_vagas
  from sessoes s where s.id = p_sessao_id;

  if v_evento is null then
    raise exception 'Sessao nao encontrada' using errcode='P0002';
  end if;

  select count(*) into v_ocupadas from sessao_convidados
   where sessao_id = p_sessao_id and status = 'confirmado';

  if v_ocupadas >= v_vagas then
    raise exception 'A sessao ja tem % de % vaga(s) ocupada(s)', v_ocupadas, v_vagas
      using errcode='22023';
  end if;

  -- gestor: reaproveita pelo e-mail; sem e-mail, cria sempre novo
  if coalesce(trim(p_email),'') <> '' then
    select g.id into v_gestor from gestores g
     where g.email_norm = norm_doc(p_email);
    v_reaproveitado := v_gestor is not null;
  end if;

  if v_gestor is null then
    insert into gestores (nome, email, empresa, cargo, telefone, perfil, origem)
    values (trim(p_nome),
            -- e-mail e chave unica; sem ele geramos um interno para nao
            -- colidir com outra pessoa sem e-mail
            coalesce(nullif(lower(trim(p_email)),''),
                     'avulso.' || replace(gen_random_uuid()::text,'-','')
                     || '@interno.ciocerrado.com.br'),
            p_empresa, p_cargo, p_telefone,
            coalesce(nullif(trim(p_rotulo),''), 'CONVIDADO'), 'manual')
    returning id into v_gestor;
  end if;

  -- participante do evento, ja aprovado: convidado avulso nao passa
  -- pela fila de aprovacao
  select pa.id into v_part from participantes pa
   where pa.evento_id = v_evento and pa.gestor_id = v_gestor;

  if v_part is null then
    insert into participantes (evento_id, gestor_id, status, origem, aprovado_em,
                               aprovado_por)
    values (v_evento, v_gestor, 'aprovado', 'manual', now(),
            auth.jwt() ->> 'email')
    returning id into v_part;
  else
    update participantes set status = 'aprovado'
     where id = v_part and status <> 'aprovado';
  end if;

  insert into sessao_convidados (sessao_id, participante_id, origem, rotulo)
  values (p_sessao_id, v_part, 'admin', nullif(trim(p_rotulo),''))
  on conflict do nothing;

  if v_ocupadas + 1 >= v_vagas then
    update sessoes set escolha_encerrada_em = now() where id = p_sessao_id;
  end if;

  return jsonb_build_object('ok', true, 'participante_id', v_part,
                            'gestor_reaproveitado', v_reaproveitado);
end;
$$;


ALTER FUNCTION "gestao"."admin_convidado_avulso"("p_sessao_id" "uuid", "p_nome" "text", "p_empresa" "text", "p_email" "text", "p_telefone" "text", "p_cargo" "text", "p_rotulo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_convidados_sessao"("p_sessao_id" "uuid") RETURNS TABLE("participante_id" "uuid", "nome" "text", "empresa" "text", "cargo" "text", "email" "text", "origem" "text", "rotulo" "text", "aderencia" numeric)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select sc.participante_id, g.nome, g.empresa, g.cargo, g.email,
           sc.origem, sc.rotulo, sc.aderencia
    from sessao_convidados sc
    join participantes pa on pa.id = sc.participante_id
    join gestores g on g.id = pa.gestor_id
    where sc.sessao_id = p_sessao_id and sc.status = 'confirmado'
    order by g.empresa, g.nome;
end;
$$;


ALTER FUNCTION "gestao"."admin_convidados_sessao"("p_sessao_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_criar_faixa_quartos"("p_evento_slug" "text", "p_de" integer, "p_ate" integer, "p_tipo" "text", "p_bloco" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_evento uuid; v_cap int; v_criados int := 0; v_n int; v_num text;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if p_tipo not in ('single','duplo','triplo') then
    raise exception 'Tipo invalido' using errcode='22023';
  end if;
  if p_de is null or p_ate is null or p_ate < p_de then
    raise exception 'Faixa invalida' using errcode='22023';
  end if;
  if p_ate - p_de > 500 then
    raise exception 'Faixa muito grande (maximo 500 por vez)'
      using errcode='22023';
  end if;

  v_cap := case p_tipo when 'single' then 1 when 'duplo' then 2 else 3 end;

  for v_n in p_de .. p_ate loop
    v_num := lpad(v_n::text, 3, '0');
    -- numero repetido e ignorado: rodar de novo completa a faixa em vez
    -- de dar erro no meio
    insert into quartos (evento_id, numero, tipo, capacidade, bloco, status)
    values (v_evento, v_num, p_tipo, v_cap, p_bloco, 'disponivel')
    on conflict do nothing;
    if found then v_criados := v_criados + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'criados', v_criados,
                            'faixa', p_de || '-' || p_ate);
end;
$$;


ALTER FUNCTION "gestao"."admin_criar_faixa_quartos"("p_evento_slug" "text", "p_de" integer, "p_ate" integer, "p_tipo" "text", "p_bloco" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_definir_patrocinadores_cota"("p_cota_id" "uuid", "p_patrocinadores" "uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_evento uuid; v_dentro int; v_fora int;
begin
  perform _exige_admin();

  select evento_id into v_evento from cotas where id = p_cota_id;
  if v_evento is null then
    raise exception 'Cota nao encontrada' using errcode='P0002';
  end if;

  -- tira da cota quem nao esta mais na lista
  update patrocinadores set cota_id = null
   where cota_id = p_cota_id
     and not (id = any(coalesce(p_patrocinadores, '{}'::uuid[])));
  get diagnostics v_fora = row_count;

  -- so aceita patrocinador do mesmo evento
  update patrocinadores set cota_id = p_cota_id
   where id = any(coalesce(p_patrocinadores, '{}'::uuid[]))
     and evento_id = v_evento;
  get diagnostics v_dentro = row_count;

  return jsonb_build_object('ok', true, 'na_cota', v_dentro, 'removidos', v_fora);
end;
$$;


ALTER FUNCTION "gestao"."admin_definir_patrocinadores_cota"("p_cota_id" "uuid", "p_patrocinadores" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_empresas_da_rodada"("p_rodada" "text") RETURNS TABLE("empresa" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select distinct pr.empresa
    from prospeccoes pr
    where coalesce(pr.sessao_id::text, 'sem-sessao-' || pr.evento_id::text) = p_rodada
      and pr.status in ('aprovado','convidado')
      and coalesce(trim(pr.empresa),'') <> '';
end;
$$;


ALTER FUNCTION "gestao"."admin_empresas_da_rodada"("p_rodada" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_enriquecer_patrocinador"("p_id" "uuid", "p_site" "text" DEFAULT NULL::"text", "p_resumo" "text" DEFAULT NULL::"text", "p_o_que_vende" "text" DEFAULT NULL::"text", "p_segmento" "text" DEFAULT NULL::"text", "p_natureza" "text" DEFAULT NULL::"text", "p_cidade" "text" DEFAULT NULL::"text", "p_estado" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_admin();

  update patrocinadores set
    site        = coalesce(nullif(trim(p_site),''), site),
    resumo      = coalesce(nullif(trim(p_resumo),''), resumo),
    o_que_vende = coalesce(nullif(trim(p_o_que_vende),''), o_que_vende),
    segmento    = coalesce(nullif(trim(p_segmento),''), segmento),
    natureza    = coalesce(nullif(trim(p_natureza),''), natureza),
    cidade      = coalesce(nullif(trim(p_cidade),''), cidade),
    estado      = coalesce(nullif(trim(p_estado),''), estado),
    enriquecido_em = now()
  where id = p_id;

  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_enriquecer_patrocinador"("p_id" "uuid", "p_site" "text", "p_resumo" "text", "p_o_que_vende" "text", "p_segmento" "text", "p_natureza" "text", "p_cidade" "text", "p_estado" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_estados_base"() RETURNS TABLE("estado" "text", "empresas" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select g.estado, count(distinct lower(trim(g.empresa)))
    from gestores g
    where g.ativo and coalesce(trim(g.estado),'') <> ''
    group by g.estado
    order by 2 desc;
end;
$$;


ALTER FUNCTION "gestao"."admin_estados_base"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_etiquetas"("p_evento_slug" "text", "p_categoria" "text" DEFAULT NULL::"text", "p_origem" "text" DEFAULT NULL::"text") RETURNS TABLE("apto" "text", "nome" "text", "empresa" "text", "categoria" "text", "origem" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select v.apto, v.nome, v.empresa, v.categoria, v.origem
    from v_etiquetas v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    where (p_categoria is null or v.categoria = p_categoria)
      and (p_origem is null or v.origem = p_origem)
    -- ordem de impressao: primeiro quem tem quarto, por numero; depois
    -- quem nao tem, em ordem alfabetica
    order by
      (v.apto is null),
      nullif(regexp_replace(coalesce(v.apto,''),'[^0-9]','','g'),'')::int nulls last,
      v.categoria, v.nome;
end;
$$;


ALTER FUNCTION "gestao"."admin_etiquetas"("p_evento_slug" "text", "p_categoria" "text", "p_origem" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_etiquetas_resumo"("p_evento_slug" "text") RETURNS TABLE("origem" "text", "categoria" "text", "total" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select v.origem, v.categoria, count(*)
    from v_etiquetas v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    group by v.origem, v.categoria
    order by v.origem, v.categoria;
end;
$$;


ALTER FUNCTION "gestao"."admin_etiquetas_resumo"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_fatura_itens"("p_fatura_id" "uuid") RETURNS TABLE("descricao" "text", "quantidade" integer, "valor_unit" numeric, "valor_total" numeric)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select fi.descricao, fi.quantidade, fi.valor_unit, fi.valor_total
    from fatura_itens fi where fi.fatura_id = p_fatura_id
    order by fi.descricao;
end;
$$;


ALTER FUNCTION "gestao"."admin_fatura_itens"("p_fatura_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_financeiro_resumo"("p_evento_slug" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_aberto numeric(12,2); v_pago numeric(12,2);
  v_n_aberto int; v_n_pago int; v_vencido int;
begin
  perform _exige_staff();

  select coalesce(sum(f.total) filter (where f.status <> 'paga'),0),
         coalesce(sum(f.total) filter (where f.status = 'paga'),0),
         count(*) filter (where f.status <> 'paga'),
         count(*) filter (where f.status = 'paga'),
         count(*) filter (where f.status <> 'paga'
                            and f.vencimento is not null
                            and f.vencimento < current_date)
    into v_aberto, v_pago, v_n_aberto, v_n_pago, v_vencido
  from faturas f
  join eventos e on e.id = f.evento_id and e.slug = p_evento_slug
  where f.status <> 'cancelada';

  return jsonb_build_object(
    'em_aberto', v_aberto, 'recebido', v_pago,
    'total', v_aberto + v_pago,
    'qtd_aberto', v_n_aberto, 'qtd_pago', v_n_pago,
    'vencidas', v_vencido);
end;
$$;


ALTER FUNCTION "gestao"."admin_financeiro_resumo"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_gerar_quartos_cota"("p_patrocinador_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid; v_cota uuid; v_extras int;
  v_comp record; v_existentes int; v_criar int; v_i int;
  v_seq int; v_total int := 0;
begin
  perform _exige_admin();

  select p.evento_id, p.cota_id, p.quartos_extras_cota
    into v_evento, v_cota, v_extras
  from patrocinadores p where p.id = p_patrocinador_id;

  if v_cota is null then
    raise exception 'Patrocinador sem cota definida' using errcode='P0002';
  end if;

  -- numeracao continua de onde parou, contando inclusive quartos extras
  select count(*) into v_seq from reservas
   where patrocinador_id = p_patrocinador_id and status <> 'cancelado';

  -- uma linha por tipo: a cota pode ter 2 duplos e 2 singles
  for v_comp in
    select tipo, quantidade from cota_quartos
    where cota_id = v_cota and quantidade > 0
    order by tipo
  loop
    select count(*) into v_existentes from reservas
     where patrocinador_id = p_patrocinador_id
       and origem = 'cota' and tipo = v_comp.tipo and status <> 'cancelado';

    v_criar := greatest(v_comp.quantidade - v_existentes, 0);

    for v_i in 1 .. v_criar loop
      v_seq := v_seq + 1;
      insert into reservas (evento_id, patrocinador_id, rotulo, tipo,
                            origem, status)
      values (v_evento, p_patrocinador_id, 'Quarto ' || v_seq,
              v_comp.tipo, 'cota', 'rascunho');
      v_total := v_total + 1;
    end loop;
  end loop;

  -- quartos extras negociados fora da cota usam o tipo mais comum dela
  if coalesce(v_extras,0) > 0 then
    select count(*) into v_existentes from reservas
     where patrocinador_id = p_patrocinador_id
       and origem = 'cota' and status <> 'cancelado';

    if v_existentes < (select coalesce(sum(quantidade),0) from cota_quartos
                       where cota_id = v_cota) + v_extras then
      for v_i in 1 .. v_extras loop
        v_seq := v_seq + 1;
        insert into reservas (evento_id, patrocinador_id, rotulo, tipo,
                              origem, status)
        values (v_evento, p_patrocinador_id, 'Quarto ' || v_seq,
                coalesce((select tipo from cota_quartos where cota_id = v_cota
                          order by quantidade desc limit 1), 'duplo'),
                'cota', 'rascunho');
        v_total := v_total + 1;
      end loop;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'criados', v_total);
end;
$$;


ALTER FUNCTION "gestao"."admin_gerar_quartos_cota"("p_patrocinador_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_gerar_quartos_todos"("p_evento_slug" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_p record; v_total int := 0; v_r jsonb;
begin
  perform _exige_admin();
  for v_p in
    select p.id from patrocinadores p
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    where p.status = 'ativo' and p.cota_id is not null
  loop
    v_r := admin_gerar_quartos_cota(v_p.id);
    v_total := v_total + (v_r ->> 'criados')::int;
  end loop;
  return jsonb_build_object('ok', true, 'reservas_criadas', v_total);
end;
$$;


ALTER FUNCTION "gestao"."admin_gerar_quartos_todos"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_gerar_sessoes"("p_evento_slug" "text", "p_tipo" "text", "p_data" "date" DEFAULT NULL::"date", "p_horario" time without time zone DEFAULT NULL::time without time zone, "p_local" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_n int := 0; v_p record;
begin
  perform _exige_admin();

  for v_p in
    select p.id, p.evento_id,
           coalesce(p.vagas_mesa_override, c.vagas_mesa_redonda) as vagas,
           c.tem_reuniao_exclusiva, c.tem_jantar
    from patrocinadores p
    join cotas c on c.id = p.cota_id
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    where p.status = 'ativo'
  loop
    -- respeita o que a cota da direito
    if p_tipo = 'reuniao_exclusiva' and not v_p.tem_reuniao_exclusiva then
      continue;
    end if;
    if p_tipo = 'jantar' and not v_p.tem_jantar then
      continue;
    end if;
    if p_tipo = 'mesa_redonda' and coalesce(v_p.vagas,0) = 0 then
      continue;
    end if;

    if exists (select 1 from sessoes s
               where s.patrocinador_id = v_p.id and s.tipo = p_tipo
                 and s.data is not distinct from p_data) then
      continue;
    end if;

    insert into sessoes (evento_id, patrocinador_id, tipo, data, horario,
                         local, vagas)
    values (v_p.evento_id, v_p.id, p_tipo, p_data, p_horario, p_local,
            coalesce(v_p.vagas, 0));
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'criadas', v_n);
end;
$$;


ALTER FUNCTION "gestao"."admin_gerar_sessoes"("p_evento_slug" "text", "p_tipo" "text", "p_data" "date", "p_horario" time without time zone, "p_local" "text") OWNER TO "postgres";


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


ALTER FUNCTION "gestao"."admin_importar_gestores"("p_linhas" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_importar_pesquisa"("p_evento_slug" "text", "p_linhas" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid;
  v_item jsonb;
  v_part uuid;
  v_email text;
  v_ok int := 0; v_nao int := 0; v_sem_email int := 0;
  v_nao_achados jsonb := '[]'::jsonb;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_linhas,'[]'::jsonb))
  loop
    v_email := nullif(trim(v_item ->> 'email'), '');

    if v_email is null then
      v_sem_email := v_sem_email + 1;
      continue;
    end if;

    select pa.id into v_part
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    where pa.evento_id = v_evento
      and g.email_norm = norm_doc(v_email)
    limit 1;

    if v_part is null then
      v_nao := v_nao + 1;
      -- guarda so os 50 primeiros: a tela mostra a lista, nao um dump
      if jsonb_array_length(v_nao_achados) < 50 then
        v_nao_achados := v_nao_achados || jsonb_build_object(
          'email', v_email, 'nome', v_item ->> 'nome');
      end if;
      continue;
    end if;

    insert into participante_perfil (
      participante_id, faturamento, orcamento_ti, colaboradores,
      colaboradores_ti, erp_atual, respostas, consentimento_lgpd)
    values (
      v_part,
      nullif(v_item ->> 'faturamento',''),
      nullif(v_item ->> 'orcamento_ti',''),
      nullif(v_item ->> 'colaboradores',''),
      nullif(v_item ->> 'colaboradores_ti',''),
      nullif(v_item ->> 'erp_atual',''),
      jsonb_build_object(
        'investimentos', coalesce(v_item -> 'investimentos', '{}'::jsonb),
        'perfil',        coalesce(v_item -> 'perfil', '{}'::jsonb),
        'dispositivos',  v_item ->> 'dispositivos',
        'terceirizados', v_item ->> 'terceirizados'),
      -- qualquer variacao de "aceito" conta como consentimento
      (lower(coalesce(v_item ->> 'consentimento_lgpd','')) like '%aceit%')
    )
    on conflict (participante_id) do update set
      faturamento      = coalesce(excluded.faturamento, participante_perfil.faturamento),
      orcamento_ti     = coalesce(excluded.orcamento_ti, participante_perfil.orcamento_ti),
      colaboradores    = coalesce(excluded.colaboradores, participante_perfil.colaboradores),
      colaboradores_ti = coalesce(excluded.colaboradores_ti, participante_perfil.colaboradores_ti),
      erp_atual        = coalesce(excluded.erp_atual, participante_perfil.erp_atual),
      respostas        = excluded.respostas,
      consentimento_lgpd = excluded.consentimento_lgpd,
      updated_at       = now();

    v_ok := v_ok + 1;
  end loop;

  insert into importacoes (evento_id, tipo, total_linhas, atualizados,
                           erros, executado_por)
  values (v_evento, 'pesquisa',
          jsonb_array_length(coalesce(p_linhas,'[]'::jsonb)),
          v_ok, v_nao + v_sem_email, auth.jwt() ->> 'email');

  return jsonb_build_object(
    'ok', true, 'importados', v_ok,
    'nao_encontrados', v_nao, 'sem_email', v_sem_email,
    'lista_nao_encontrados', v_nao_achados);
end;
$$;


ALTER FUNCTION "gestao"."admin_importar_pesquisa"("p_evento_slug" "text", "p_linhas" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_alocacao"("p_evento_slug" "text", "p_apenas_sem_quarto" boolean DEFAULT false) RETURNS TABLE("ocupante_id" "uuid", "reserva_id" "uuid", "nome" "text", "empresa" "text", "tipo" "text", "quarto_id" "uuid", "quarto_numero" "text", "quarto_tipo" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select o.id, r.id, o.nome,
           coalesce(p.empresa, g.empresa),
           o.tipo, q.id, q.numero, r.tipo
    from ocupantes o
    join reservas r on r.id = o.reserva_id and r.status <> 'cancelado'
    join eventos  e on e.id = r.evento_id and e.slug = p_evento_slug
    left join quartos q on q.id = r.quarto_id
    left join patrocinadores p on p.id = r.patrocinador_id
    left join participantes pa on pa.id = r.participante_id
    left join gestores g on g.id = pa.gestor_id
    where (not p_apenas_sem_quarto or r.quarto_id is null)
    order by coalesce(p.empresa, g.empresa), o.nome;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_alocacao"("p_evento_slug" "text", "p_apenas_sem_quarto" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_cotas"("p_evento_slug" "text") RETURNS TABLE("id" "uuid", "nome" "text", "ordem_prioridade" integer, "quartos" "jsonb", "total_quartos" bigint, "vagas_mesa_redonda" integer, "tem_reuniao_exclusiva" boolean, "tem_jantar" boolean, "patrocinadores" bigint, "lista_patrocinadores" "jsonb", "prazo_indicacao" "date", "janela_horas" integer)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select c.id, c.nome, c.ordem_prioridade,
           coalesce((select jsonb_object_agg(cq.tipo, cq.quantidade)
                     from cota_quartos cq where cq.cota_id = c.id
                       and cq.quantidade > 0), '{}'::jsonb),
           coalesce((select sum(cq.quantidade) from cota_quartos cq
                     where cq.cota_id = c.id), 0),
           c.vagas_mesa_redonda, c.tem_reuniao_exclusiva, c.tem_jantar,
           (select count(*) from patrocinadores p where p.cota_id = c.id),
           coalesce((select jsonb_agg(jsonb_build_object(
                       'id', p.id, 'empresa', p.empresa) order by p.empresa)
                     from patrocinadores p
                     where p.cota_id = c.id and p.status = 'ativo'), '[]'::jsonb),
           c.prazo_indicacao, c.janela_horas
    from cotas c
    join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_cotas"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_equipe"() RETURNS TABLE("id" "uuid", "email" "text", "nome" "text", "role" "text", "ativo" boolean, "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select a.id, a.email, a.nome, a.role, a.ativo, a.created_at
    from admins a
    order by a.role, a.email;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_equipe"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_eventos"() RETURNS TABLE("id" "uuid", "slug" "text", "nome" "text", "local" "text", "data_inicio" "date", "data_fim" "date", "status" "text", "cota_unica" boolean, "prazo_contrato" "date", "prazo_rooming" "date", "prazo_cancelamento" "date", "participantes" bigint, "escolha_abre_em" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select e.id, e.slug, e.nome, e.local, e.data_inicio, e.data_fim,
           e.status, e.cota_unica,
           e.prazo_contrato, e.prazo_rooming, e.prazo_cancelamento,
           (select count(*) from participantes p where p.evento_id = e.id),
           e.escolha_abre_em
    from eventos e
    order by e.data_inicio desc nulls last;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_eventos"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_faturas"("p_evento_slug" "text", "p_status" "text" DEFAULT NULL::"text", "p_limite" integer DEFAULT 500, "p_offset" integer DEFAULT 0) RETURNS TABLE("id" "uuid", "tipo" "text", "nome" "text", "empresa" "text", "email" "text", "total" numeric, "status" "text", "vencimento" "date", "emitida_em" timestamp with time zone, "paga_em" timestamp with time zone, "forma_pagamento" "text", "observacao" "text", "itens" "text", "total_geral" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select f.id,
           case when f.participante_id is not null then 'participante'
                else 'patrocinador' end,
           coalesce(g.nome, p.empresa),
           coalesce(g.empresa, p.empresa),
           coalesce(g.email, (select u.email from usuarios_patrocinador u
                              where u.patrocinador_id = p.id and u.ativo
                              order by u.created_at limit 1)),
           f.total, f.status, f.vencimento,
           f.emitida_em, f.paga_em, f.forma_pagamento, f.observacao,
           -- resumo dos itens em uma linha: evita segunda consulta so
           -- para mostrar "1 acompanhante + transfer"
           coalesce((select string_agg(fi.descricao || ' ×' || fi.quantidade, ', '
                                       order by fi.descricao)
                     from fatura_itens fi where fi.fatura_id = f.id), '—'),
           count(*) over ()
    from faturas f
    join eventos e on e.id = f.evento_id and e.slug = p_evento_slug
    left join participantes pa on pa.id = f.participante_id
    left join gestores g on g.id = pa.gestor_id
    left join patrocinadores p on p.id = f.patrocinador_id
    where f.status <> 'cancelada'
      and (p_status is null or f.status = p_status)
    order by (f.status = 'paga'), f.total desc
    limit p_limite offset p_offset;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_faturas"("p_evento_slug" "text", "p_status" "text", "p_limite" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_indicacoes"("p_evento_slug" "text", "p_status" "text" DEFAULT NULL::"text") RETURNS TABLE("indicacao_id" "uuid", "patrocinador" "text", "nome" "text", "empresa" "text", "cargo" "text", "email" "text", "telefone" "text", "observacao" "text", "status" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select i.id, p.empresa, i.nome, i.empresa, i.cargo, i.email,
           i.telefone, i.observacao, i.status, i.created_at
    from indicacoes i
    join patrocinadores p on p.id = i.patrocinador_id
    join eventos e on e.id = i.evento_id and e.slug = p_evento_slug
    where p_status is null or i.status = p_status
    order by i.created_at desc;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_indicacoes"("p_evento_slug" "text", "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_patrocinadores"("p_evento_slug" "text") RETURNS TABLE("id" "uuid", "empresa" "text", "cnpj" "text", "segmento" "text", "site" "text", "resumo" "text", "o_que_vende" "text", "natureza" "text", "cidade" "text", "estado" "text", "cota" "text", "ordem" integer, "quartos_extras" integer, "vagas_mesa_override" integer, "status" "text", "fechado_em" timestamp with time zone, "enriquecido_em" timestamp with time zone, "usuarios" bigint, "reservas" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select p.id, p.empresa, p.cnpj, p.segmento,
           p.site, p.resumo, p.o_que_vende, p.natureza,
           p.cidade, p.estado,
           c.nome, c.ordem_prioridade, p.quartos_extras_cota,
           p.vagas_mesa_override, p.status, p.fechado_em, p.enriquecido_em,
           (select count(*) from usuarios_patrocinador u
             where u.patrocinador_id = p.id and u.ativo),
           (select count(*) from reservas r
             where r.patrocinador_id = p.id and r.status <> 'cancelado')
    from patrocinadores p
    left join cotas c on c.id = p.cota_id
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade nulls last, p.empresa;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_patrocinadores"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_pendentes"("p_evento_slug" "text") RETURNS TABLE("participante_id" "uuid", "nome" "text", "empresa" "text", "cargo" "text", "email" "text", "telefone" "text", "origem" "text", "indicado_por" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select pa.id, g.nome, g.empresa, g.cargo, g.email, g.telefone,
           pa.origem, pt.empresa, pa.created_at
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    join eventos  e on e.id = pa.evento_id and e.slug = p_evento_slug
    left join patrocinadores pt on pt.id = pa.indicado_por_patrocinador_id
    where pa.status = 'pendente'
    order by pa.created_at;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_pendentes"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_precos"("p_evento_slug" "text") RETURNS TABLE("id" "uuid", "item" "text", "descricao" "text", "valor" numeric, "idade_min" integer, "idade_max" integer, "faixa" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select pr.id, pr.item, pr.descricao, pr.valor,
           pr.idade_min, pr.idade_max,
           _rotulo_faixa(pr.idade_min, pr.idade_max)
    from precos pr
    join eventos e on e.id = pr.evento_id and e.slug = p_evento_slug
    order by pr.item, pr.idade_min nulls first;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_precos"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_prospeccao"("p_evento_slug" "text", "p_sessao_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "empresa" "text", "nome" "text", "cargo" "text", "email" "text", "telefone" "text", "score" numeric, "natureza" "text", "justificativa" "text", "status" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select pr.id, pr.empresa, g.nome, g.cargo, g.email, g.telefone,
           pr.score, pr.natureza, pr.justificativa, pr.status
    from prospeccoes pr
    left join gestores g on g.id = pr.gestor_id
    join eventos e on e.id = pr.evento_id and e.slug = p_evento_slug
    where (p_sessao_id is null or pr.sessao_id = p_sessao_id)
    order by pr.score desc nulls last, pr.empresa;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_prospeccao"("p_evento_slug" "text", "p_sessao_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_rodadas"() RETURNS TABLE("rodada_id" "text", "evento" "text", "patrocinador" "text", "quando" timestamp with time zone, "empresas" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select coalesce(pr.sessao_id::text, 'sem-sessao-' || pr.evento_id::text),
           e.nome,
           coalesce(p.empresa, '—'),
           max(pr.created_at),
           count(distinct lower(trim(pr.empresa)))
    from prospeccoes pr
    join eventos e on e.id = pr.evento_id
    left join patrocinadores p on p.id = pr.patrocinador_id
    where pr.status in ('aprovado','convidado')
    group by 1, 2, 3
    order by 4 desc;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_rodadas"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_sessoes"("p_evento_slug" "text", "p_tipo" "text" DEFAULT NULL::"text") RETURNS TABLE("sessao_id" "uuid", "patrocinador" "text", "cota" "text", "tipo" "text", "data" "date", "horario" time without time zone, "local" "text", "vagas" integer, "escolhidos" bigint, "encerrada" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select s.id, p.empresa, c.nome, s.tipo, s.data, s.horario, s.local,
           s.vagas,
           (select count(*) from sessao_convidados sc
             where sc.sessao_id = s.id and sc.status = 'confirmado'),
           (s.escolha_encerrada_em is not null or s.passou_em is not null)
    from sessoes s
    join patrocinadores p on p.id = s.patrocinador_id
    left join cotas c on c.id = p.cota_id
    join eventos e on e.id = s.evento_id and e.slug = p_evento_slug
    where p_tipo is null or s.tipo = p_tipo
    order by c.ordem_prioridade nulls last, p.empresa, s.data;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_sessoes"("p_evento_slug" "text", "p_tipo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_sugestoes"("p_status" "text" DEFAULT 'pendente'::"text") RETURNS TABLE("id" "uuid", "tipo" "text", "gestor_nome" "text", "empresa" "text", "campo" "text", "valor_atual" "text", "valor_sugerido" "text", "confianca" numeric, "fonte" "text", "justificativa" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select s.id, s.tipo, g.nome, coalesce(s.empresa, g.empresa), s.campo,
           s.valor_atual, s.valor_sugerido, s.confianca, s.fonte,
           s.justificativa, s.created_at
    from sugestoes_ia s
    left join gestores g on g.id = s.gestor_id
    where s.status = p_status
    order by s.confianca desc nulls last, s.created_at;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_sugestoes"("p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_usuarios_patro"("p_patrocinador_id" "uuid") RETURNS TABLE("id" "uuid", "email" "text", "nome" "text", "telefone" "text", "ativo" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select u.id, u.email, u.nome, u.telefone, u.ativo
    from usuarios_patrocinador u
    where u.patrocinador_id = p_patrocinador_id
    order by u.email;
end;
$$;


ALTER FUNCTION "gestao"."admin_listar_usuarios_patro"("p_patrocinador_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_localidades_base"() RETURNS TABLE("cidade" "text", "estado" "text", "empresas" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select coalesce(nullif(trim(g.cidade),''), '—'),
           coalesce(nullif(trim(g.estado),''), '—'),
           count(distinct lower(trim(g.empresa)))
    from gestores g
    where g.ativo and coalesce(trim(g.empresa),'') <> ''
    group by 1, 2
    order by 3 desc, 1;
end;
$$;


ALTER FUNCTION "gestao"."admin_localidades_base"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_mailing_sessao"("p_sessao_id" "uuid") RETURNS TABLE("nome" "text", "cargo" "text", "empresa" "text", "email" "text", "telefone" "text", "rotulo" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select g.nome, g.cargo, g.empresa,
           -- e-mail interno gerado para quem nao tem: nao vai no mailing
           case when g.email like '%@interno.ciocerrado.com.br' then null
                else g.email end,
           g.telefone,
           coalesce(sc.rotulo, g.perfil)
    from sessao_convidados sc
    join participantes pa on pa.id = sc.participante_id
    join gestores g on g.id = pa.gestor_id
    where sc.sessao_id = p_sessao_id and sc.status = 'confirmado'
    order by g.empresa, g.nome;
end;
$$;


ALTER FUNCTION "gestao"."admin_mailing_sessao"("p_sessao_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_marcar_fatura"("p_fatura_id" "uuid", "p_status" "text", "p_forma_pagamento" "text" DEFAULT NULL::"text", "p_observacao" "text" DEFAULT NULL::"text", "p_vencimento" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_ant text;
begin
  perform _exige_admin();

  select status into v_ant from faturas where id = p_fatura_id;
  if v_ant is null then
    raise exception 'Fatura nao encontrada' using errcode='P0002';
  end if;
  if p_status not in ('estimada','emitida','paga','cancelada') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;

  update faturas set
    status = p_status,
    -- carimba a data na primeira vez que entra no estado, e limpa se
    -- voltar atras: fatura reaberta com data de pagamento antiga
    -- confunde a conferencia
    emitida_em = case
      when p_status in ('emitida','paga') then coalesce(emitida_em, now())
      else null end,
    paga_em = case
      when p_status = 'paga' then coalesce(paga_em, now())
      else null end,
    forma_pagamento = case
      when p_status = 'paga' then coalesce(p_forma_pagamento, forma_pagamento)
      else forma_pagamento end,
    observacao = coalesce(p_observacao, observacao),
    vencimento = coalesce(p_vencimento, vencimento)
  where id = p_fatura_id;

  return jsonb_build_object('ok', true, 'de', v_ant, 'para', p_status);
end;
$$;


ALTER FUNCTION "gestao"."admin_marcar_fatura"("p_fatura_id" "uuid", "p_status" "text", "p_forma_pagamento" "text", "p_observacao" "text", "p_vencimento" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_marcar_prospeccao"("p_id" "uuid", "p_status" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_admin();
  if p_status not in ('sugerido','aprovado','descartado','convidado') then
    raise exception 'Status invalido' using errcode='22023';
  end if;
  update prospeccoes set status = p_status where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_marcar_prospeccao"("p_id" "uuid", "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_match_jantar"("p_sessao_id" "uuid", "p_limite" integer DEFAULT 20) RETURNS TABLE("participante_id" "uuid", "nome" "text", "empresa" "text", "segmento" "text", "faturamento" "text", "aderencia" numeric)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_evento uuid; v_patro_seg text; v_vende text; v_tipo text;
begin
  perform _exige_staff();

  select s.evento_id, s.tipo, p.segmento, p.o_que_vende
    into v_evento, v_tipo, v_patro_seg, v_vende
  from sessoes s join patrocinadores p on p.id = s.patrocinador_id
  where s.id = p_sessao_id;

  return query
    select pa.id, g.nome, g.empresa, g.segmento, pp.faturamento,
      round(
        (case when v_patro_seg is not null
               and lower(coalesce(g.segmento,'')) = lower(v_patro_seg)
              then 50 else 0 end)
        + (case when v_vende is not null
                 and coalesce(pp.respostas::text,'') ilike '%' || v_vende || '%'
                then 30 else 0 end)
        + (case when pp.faturamento ilike '%bilh%' then 20
                when pp.faturamento ilike '%milh%' then 10
                else 0 end)
      , 2)::numeric as aderencia
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    left join participante_perfil pp on pp.participante_id = pa.id
    where pa.evento_id = v_evento
      and pa.status = 'aprovado'
      -- fora quem ja esta em qualquer sessao DESTE tipo, inclusive esta
      and not exists (
        select 1 from sessao_convidados sc
        join sessoes s3 on s3.id = sc.sessao_id
        where sc.participante_id = pa.id and sc.status = 'confirmado'
          and s3.evento_id = v_evento and s3.tipo = v_tipo)
    order by aderencia desc, g.empresa
    limit p_limite;
end;
$$;


ALTER FUNCTION "gestao"."admin_match_jantar"("p_sessao_id" "uuid", "p_limite" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_pesquisa_areas"("p_evento_slug" "text") RETURNS TABLE("area" "text", "aumentar" bigint, "estudo" bigint, "diminuir" bigint, "sem_previsao" bigint, "respondentes" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select
      inv.key,
      count(*) filter (where _intencao(inv.value #>> '{}') = 'aumentar'),
      count(*) filter (where _intencao(inv.value #>> '{}') = 'estudo'),
      count(*) filter (where _intencao(inv.value #>> '{}') = 'diminuir'),
      count(*) filter (where _intencao(inv.value #>> '{}') = 'sem_previsao'),
      count(*) filter (where _intencao(inv.value #>> '{}') is not null)
    from participante_perfil pp
    join participantes pa on pa.id = pp.participante_id
    join eventos e on e.id = pa.evento_id and e.slug = p_evento_slug
    cross join lateral jsonb_each(coalesce(pp.respostas -> 'investimentos','{}'::jsonb)) as inv
    where pa.status = 'aprovado'
    group by inv.key
    order by 2 desc, 1;
end;
$$;


ALTER FUNCTION "gestao"."admin_pesquisa_areas"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_pesquisa_por_area"("p_evento_slug" "text", "p_area" "text", "p_intencao" "text" DEFAULT 'aumentar'::"text") RETURNS TABLE("nome" "text", "empresa" "text", "cargo" "text", "email" "text", "segmento" "text", "faturamento" "text", "resposta" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select g.nome, g.empresa, g.cargo, g.email, g.segmento,
           pp.faturamento,
           (pp.respostas -> 'investimentos' ->> p_area)
    from participante_perfil pp
    join participantes pa on pa.id = pp.participante_id
    join gestores g on g.id = pa.gestor_id
    join eventos e on e.id = pa.evento_id and e.slug = p_evento_slug
    where pa.status = 'aprovado'
      and _intencao(pp.respostas -> 'investimentos' ->> p_area) = p_intencao
    order by g.empresa, g.nome;
end;
$$;


ALTER FUNCTION "gestao"."admin_pesquisa_por_area"("p_evento_slug" "text", "p_area" "text", "p_intencao" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_pesquisa_resumo"("p_evento_slug" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_total int; v_resp int; v_lgpd int;
begin
  perform _exige_staff();

  select count(*) into v_total
  from participantes pa
  join eventos e on e.id = pa.evento_id and e.slug = p_evento_slug
  where pa.status = 'aprovado';

  select count(*), count(*) filter (where pp.consentimento_lgpd)
    into v_resp, v_lgpd
  from participante_perfil pp
  join participantes pa on pa.id = pp.participante_id
  join eventos e on e.id = pa.evento_id and e.slug = p_evento_slug
  where pa.status = 'aprovado';

  return jsonb_build_object(
    'aprovados', v_total,
    'responderam', v_resp,
    'faltam', greatest(v_total - v_resp, 0),
    'consentiram_lgpd', v_lgpd);
end;
$$;


ALTER FUNCTION "gestao"."admin_pesquisa_resumo"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_prospeccao_base"("p_evento_slug" "text", "p_excluir_fornecedores" boolean DEFAULT true, "p_excluir_empresas" "text"[] DEFAULT NULL::"text"[], "p_excluir_convidados" boolean DEFAULT true, "p_tipo_sessao" "text" DEFAULT 'jantar'::"text", "p_limite" integer DEFAULT 500) RETURNS TABLE("empresa" "text", "segmento" "text", "faturamento" "text", "funcionarios" "text", "cidade" "text", "estado" "text", "cnpj" "text", "exec1_id" "uuid", "exec1_nome" "text", "exec1_cargo" "text", "exec1_email" "text", "exec1_telefone" "text", "exec2_id" "uuid", "exec2_nome" "text", "exec2_cargo" "text", "exec2_email" "text", "exec2_telefone" "text", "contatos" bigint, "ja_convidado_em" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();

  return query
  with
  ja as (
    select lower(trim(g.empresa)) as empresa,
           string_agg(distinct ev.nome, ', ') as eventos
    from sessao_convidados sc
    join sessoes s   on s.id = sc.sessao_id and s.tipo = p_tipo_sessao
    join eventos ev  on ev.id = s.evento_id
    join participantes pa on pa.id = sc.participante_id
    join gestores g  on g.id = pa.gestor_id
    where sc.status = 'confirmado'
      and coalesce(trim(g.empresa),'') <> ''
    group by lower(trim(g.empresa))
  ),
  bloqueadas as (
    select lower(trim(x)) as empresa
    from unnest(coalesce(p_excluir_empresas, '{}'::text[])) as x
  ),
  ranqueado as (
    select g.*,
           row_number() over (
             partition by lower(trim(g.empresa))
             -- POSICAO GESTOR primeiro, cargo como desempate
             order by _rank_pos(g.posicao_gestor), _rank_cargo(g.cargo), g.nome) as pos,
           count(*) over (partition by lower(trim(g.empresa))) as n
    from gestores g
    where g.ativo
      and coalesce(trim(g.empresa),'') <> ''
      and coalesce(trim(g.nome),'') <> ''
      and (not p_excluir_fornecedores
           or coalesce(upper(unaccent('unaccent', g.perfil)),'')
              not like '%FORNECEDOR%')
  )
  select
    a.empresa, a.segmento, a.faturamento, a.funcionarios,
    a.cidade, a.estado, a.cnpj,
    a.id, a.nome, a.cargo, a.email, a.telefone,
    b.id, b.nome, b.cargo, b.email, b.telefone,
    a.n,
    j.eventos
  from ranqueado a
  left join ranqueado b
    on lower(trim(b.empresa)) = lower(trim(a.empresa)) and b.pos = 2
  left join ja j on j.empresa = lower(trim(a.empresa))
  left join bloqueadas bl on bl.empresa = lower(trim(a.empresa))
  where a.pos = 1
    and bl.empresa is null
    and (not p_excluir_convidados or j.empresa is null)
  order by a.empresa
  limit p_limite;
end;
$$;


ALTER FUNCTION "gestao"."admin_prospeccao_base"("p_evento_slug" "text", "p_excluir_fornecedores" boolean, "p_excluir_empresas" "text"[], "p_excluir_convidados" boolean, "p_tipo_sessao" "text", "p_limite" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_quartos_livres"("p_evento_slug" "text") RETURNS TABLE("id" "uuid", "numero" "text", "tipo" "text", "capacidade" integer)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select q.id, q.numero, q.tipo, q.capacidade
    from quartos q
    join eventos e on e.id = q.evento_id and e.slug = p_evento_slug
    where q.status <> 'bloqueado'
      and not exists (select 1 from reservas r
                      where r.quarto_id = q.id and r.status <> 'cancelado')
    order by q.numero nulls last;
end;
$$;


ALTER FUNCTION "gestao"."admin_quartos_livres"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_recalcular_faturas"("p_evento_slug" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid; v_r record; v_np int := 0; v_ns int := 0;
  v_total numeric(12,2) := 0; v_v numeric(12,2);
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;

  for v_r in
    select pa.id from participantes pa
    where pa.evento_id = v_evento and pa.status = 'aprovado'
  loop
    v_v := _recalcular_fatura_participante(v_r.id);
    if v_v > 0 then v_np := v_np + 1; v_total := v_total + v_v; end if;
  end loop;

  for v_r in
    select p.id from patrocinadores p
    where p.evento_id = v_evento and p.status = 'ativo'
  loop
    v_v := _recalcular_fatura_patrocinador(v_r.id);
    if v_v > 0 then v_ns := v_ns + 1; v_total := v_total + v_v; end if;
  end loop;

  return jsonb_build_object('ok', true, 'participantes', v_np,
                            'patrocinadores', v_ns, 'total', v_total);
end;
$$;


ALTER FUNCTION "gestao"."admin_recalcular_faturas"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_registrar_sugestao"("p_tipo" "text", "p_gestor_id" "uuid" DEFAULT NULL::"uuid", "p_empresa" "text" DEFAULT NULL::"text", "p_campo" "text" DEFAULT NULL::"text", "p_valor_atual" "text" DEFAULT NULL::"text", "p_valor_sugerido" "text" DEFAULT NULL::"text", "p_confianca" numeric DEFAULT NULL::numeric, "p_fonte" "text" DEFAULT NULL::"text", "p_justificativa" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_id uuid;
begin
  perform _exige_admin();

  insert into sugestoes_ia (tipo, gestor_id, empresa, campo, valor_atual,
                            valor_sugerido, confianca, fonte, justificativa)
  values (p_tipo, p_gestor_id, p_empresa, p_campo, p_valor_atual,
          p_valor_sugerido, p_confianca, p_fonte, p_justificativa)
  returning id into v_id;

  return v_id;
end;
$$;


ALTER FUNCTION "gestao"."admin_registrar_sugestao"("p_tipo" "text", "p_gestor_id" "uuid", "p_empresa" "text", "p_campo" "text", "p_valor_atual" "text", "p_valor_sugerido" "text", "p_confianca" numeric, "p_fonte" "text", "p_justificativa" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_rel_checkins_detalhe"("p_evento_slug" "text", "p_empresa" "text" DEFAULT NULL::"text", "p_limite" integer DEFAULT 500, "p_offset" integer DEFAULT 0) RETURNS TABLE("empresa" "text", "nome" "text", "email" "text", "registrado_em" timestamp with time zone, "total_geral" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select p.empresa, c.nome, c.email, c.registrado_em, count(*) over ()
    from checkins c
    join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
    left join patrocinadores p on p.id = c.patrocinador_id
    where c.desfeito_em is null
      and (p_empresa is null or lower(p.empresa) = lower(p_empresa))
    order by p.empresa, c.registrado_em
    limit p_limite offset p_offset;
end;
$$;


ALTER FUNCTION "gestao"."admin_rel_checkins_detalhe"("p_evento_slug" "text", "p_empresa" "text", "p_limite" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_rel_checkins_resumo"("p_evento_slug" "text") RETURNS TABLE("empresa" "text", "total_checkins" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select v.empresa, v.total_checkins
    from v_checkins_resumo v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    order by v.total_checkins desc, v.empresa;
end;
$$;


ALTER FUNCTION "gestao"."admin_rel_checkins_resumo"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_rel_mailing"("p_evento_slug" "text", "p_limite" integer DEFAULT 500, "p_offset" integer DEFAULT 0) RETURNS TABLE("perfil" "text", "nome" "text", "cargo" "text", "empresa" "text", "email" "text", "telefone" "text", "cnpj" "text", "segmento" "text", "estado" "text", "total_geral" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select g.perfil, g.nome, g.cargo, g.empresa, g.email, g.telefone,
           g.cnpj, g.segmento, g.estado, count(*) over ()
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    join eventos  e on e.id = pa.evento_id and e.slug = p_evento_slug
    where pa.status = 'aprovado'
    order by g.nome
    limit p_limite offset p_offset;
end;
$$;


ALTER FUNCTION "gestao"."admin_rel_mailing"("p_evento_slug" "text", "p_limite" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_rel_painel"("p_evento_slug" "text", "p_limite" integer DEFAULT 500, "p_offset" integer DEFAULT 0) RETURNS TABLE("participante_id" "uuid", "nome" "text", "empresa" "text", "email" "text", "status_inscricao" "text", "status_contrato" "text", "status_rooming" "text", "usa_transfer" boolean, "quarto" "text", "total_geral" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select v.participante_id, v.nome, v.empresa, v.email,
           v.status_inscricao, v.status_contrato, v.status_rooming,
           v.usa_transfer, v.quarto,
           count(*) over ()
    from v_painel_participantes v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    order by v.empresa, v.nome
    limit p_limite offset p_offset;
end;
$$;


ALTER FUNCTION "gestao"."admin_rel_painel"("p_evento_slug" "text", "p_limite" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_rel_pesquisa"("p_evento_slug" "text", "p_limite" integer DEFAULT 500, "p_offset" integer DEFAULT 0) RETURNS TABLE("nome" "text", "empresa" "text", "cargo" "text", "email" "text", "telefone" "text", "segmento" "text", "estado" "text", "cnpj" "text", "faturamento" "text", "orcamento_ti" "text", "colaboradores" "text", "colaboradores_ti" "text", "erp_atual" "text", "dispositivos" "text", "terceirizados" "text", "consentimento_lgpd" boolean, "investimentos" "jsonb", "perfil" "jsonb", "respondeu" boolean, "total_geral" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select g.nome, g.empresa, g.cargo, g.email, g.telefone,
           g.segmento, g.estado, g.cnpj,
           pp.faturamento, pp.orcamento_ti, pp.colaboradores,
           pp.colaboradores_ti, pp.erp_atual,
           pp.respostas ->> 'dispositivos',
           pp.respostas ->> 'terceirizados',
           pp.consentimento_lgpd,
           coalesce(pp.respostas -> 'investimentos', '{}'::jsonb),
           coalesce(pp.respostas -> 'perfil', '{}'::jsonb),
           (pp.participante_id is not null),
           count(*) over ()
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    join eventos  e on e.id = pa.evento_id and e.slug = p_evento_slug
    left join participante_perfil pp on pp.participante_id = pa.id
    where pa.status = 'aprovado'
    order by (pp.participante_id is null), g.empresa, g.nome
    limit p_limite offset p_offset;
end;
$$;


ALTER FUNCTION "gestao"."admin_rel_pesquisa"("p_evento_slug" "text", "p_limite" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_remover_convidado_sessao"("p_sessao_id" "uuid", "p_participante_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();

  update sessao_convidados set status = 'removido'
   where sessao_id = p_sessao_id and participante_id = p_participante_id;

  -- vaga liberada reabre a escolha do patrocinador
  update sessoes set escolha_encerrada_em = null where id = p_sessao_id;

  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_remover_convidado_sessao"("p_sessao_id" "uuid", "p_participante_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_remover_cota"("p_cota_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_uso int; v_nome text;
begin
  perform _exige_admin();

  select nome into v_nome from cotas where id = p_cota_id;
  select count(*) into v_uso from patrocinadores where cota_id = p_cota_id;

  if v_uso > 0 then
    raise exception '% patrocinador(es) usam a cota "%". Mova-os antes.',
      v_uso, v_nome using errcode='23503';
  end if;

  delete from cotas where id = p_cota_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_remover_cota"("p_cota_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_remover_membro"("p_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_email text; v_role text; v_admins int;
begin
  perform _exige_admin();

  select email, role into v_email, v_role from admins where id = p_id;
  if v_email is null then
    raise exception 'Membro nao encontrado' using errcode = 'P0002';
  end if;

  if norm_doc(v_email) = norm_doc(auth.jwt() ->> 'email') then
    raise exception 'Voce nao pode remover o proprio acesso'
      using errcode = '42501';
  end if;

  if v_role = 'admin' then
    select count(*) into v_admins from admins
     where role = 'admin' and ativo;
    if v_admins <= 1 then
      raise exception 'Este e o ultimo administrador ativo'
        using errcode = '42501';
    end if;
  end if;

  delete from admins where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_remover_membro"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_remover_patrocinador"("p_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_preenchidas int; v_nome text;
begin
  perform _exige_admin();

  select empresa into v_nome from patrocinadores where id = p_id;

  -- Apagar levaria junto reservas, ocupantes e escolhas de mesa.
  -- Se ja ha quarto preenchido, o certo e inativar, nao destruir.
  select count(*) into v_preenchidas from reservas
   where patrocinador_id = p_id and status = 'completo';

  if v_preenchidas > 0 then
    raise exception
      '"%" ja tem % quarto(s) preenchido(s). Marque como inativo em vez de remover.',
      v_nome, v_preenchidas using errcode='23503';
  end if;

  delete from patrocinadores where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_remover_patrocinador"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_remover_preco"("p_preco_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_item text; v_evento uuid; v_restam int;
begin
  perform _exige_admin();

  select item, evento_id into v_item, v_evento from precos where id = p_preco_id;
  if v_item is null then
    raise exception 'Preco nao encontrado' using errcode='P0002';
  end if;

  select count(*) into v_restam from precos
   where evento_id = v_evento and item = v_item and id <> p_preco_id;

  if v_restam = 0 and v_item in ('acompanhante_adulto','crianca','transfer') then
    raise exception
      'O item "%" e usado no calculo da fatura. Para nao cobrar, deixe o valor em zero.',
      v_item using errcode='42501';
  end if;

  delete from precos where id = p_preco_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_remover_preco"("p_preco_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_remover_quartos_livres"("p_evento_slug" "text", "p_tipo" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_n int;
begin
  perform _exige_admin();

  -- so remove o que nao esta reservado: quarto com gente dentro fica
  with alvo as (
    select q.id from quartos q
    join eventos e on e.id = q.evento_id and e.slug = p_evento_slug
    where (p_tipo is null or q.tipo = p_tipo)
      and not exists (select 1 from reservas r
                      where r.quarto_id = q.id and r.status <> 'cancelado')
  )
  delete from quartos where id in (select id from alvo);

  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'removidos', v_n);
end;
$$;


ALTER FUNCTION "gestao"."admin_remover_quartos_livres"("p_evento_slug" "text", "p_tipo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_remover_sessao"("p_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_ja int;
begin
  perform _exige_admin();

  select count(*) into v_ja from sessao_convidados
   where sessao_id = p_id and status = 'confirmado';

  if v_ja > 0 then
    raise exception 'Ha % convidado(s) confirmado(s) nesta sessao', v_ja
      using errcode='23503';
  end if;

  delete from sessoes where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_remover_sessao"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_remover_usuario_patro"("p_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_admin();
  delete from usuarios_patrocinador where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_remover_usuario_patro"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_resumo_quartos"("p_evento_slug" "text") RETURNS TABLE("tipo" "text", "total" bigint, "livres" bigint, "ocupados" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select q.tipo, count(*),
           count(*) filter (where not exists (
             select 1 from reservas r where r.quarto_id = q.id
               and r.status <> 'cancelado')),
           count(*) filter (where exists (
             select 1 from reservas r where r.quarto_id = q.id
               and r.status <> 'cancelado'))
    from quartos q
    join eventos e on e.id = q.evento_id and e.slug = p_evento_slug
    group by q.tipo
    order by q.tipo;
end;
$$;


ALTER FUNCTION "gestao"."admin_resumo_quartos"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_salvar_cota"("p_evento_slug" "text", "p_nome" "text", "p_ordem" integer, "p_quartos" "jsonb" DEFAULT '{}'::"jsonb", "p_vagas_mesa" integer DEFAULT 0, "p_reuniao" boolean DEFAULT false, "p_jantar" boolean DEFAULT false, "p_prazo_indicacao" "date" DEFAULT NULL::"date", "p_janela_horas" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid; v_unica boolean; v_conflito text;
  v_cota uuid; v_par record; v_ordem int; v_total int := 0;
begin
  perform _exige_admin();

  select id, cota_unica into v_evento, v_unica
  from eventos where slug = p_evento_slug;

  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome da cota' using errcode='22023';
  end if;
  if p_janela_horas is not null and p_janela_horas <= 0 then
    raise exception 'A janela em horas comeca em 1' using errcode='22023';
  end if;

  -- Em evento de cota unica nao ha fila, entao a ordem nao e pedida na
  -- tela; forcamos 1 para nao deixar nulo e quebrar a view de ordem.
  v_ordem := case when v_unica then 1 else p_ordem end;

  if v_ordem is null or v_ordem < 1 then
    raise exception 'A ordem de prioridade comeca em 1' using errcode='22023';
  end if;

  if not v_unica then
    select c.nome into v_conflito from cotas c
     where c.evento_id = v_evento and c.ordem_prioridade = v_ordem
       and lower(c.nome) <> lower(trim(p_nome));
    if v_conflito is not null then
      raise exception 'A posicao % ja e da cota "%"', v_ordem, v_conflito
        using errcode='23505';
    end if;
  end if;

  insert into cotas (evento_id, nome, ordem_prioridade, vagas_mesa_redonda,
                     tem_reuniao_exclusiva, tem_jantar,
                     quartos_incluidos, tipo_quarto_padrao, prazo_indicacao,
                     janela_horas)
  values (v_evento, trim(p_nome), v_ordem, coalesce(p_vagas_mesa,0),
          p_reuniao, p_jantar, 0, 'duplo', p_prazo_indicacao, p_janela_horas)
  on conflict (evento_id, nome) do update set
    ordem_prioridade = excluded.ordem_prioridade,
    vagas_mesa_redonda = excluded.vagas_mesa_redonda,
    tem_reuniao_exclusiva = excluded.tem_reuniao_exclusiva,
    tem_jantar = excluded.tem_jantar,
    prazo_indicacao = excluded.prazo_indicacao,
    janela_horas = excluded.janela_horas
  returning id into v_cota;

  -- composicao substitui a anterior inteira: a tela edita o conjunto
  delete from cota_quartos where cota_id = v_cota;

  for v_par in
    select key as tipo, (value #>> '{}')::int as qtd
    from jsonb_each(coalesce(p_quartos, '{}'::jsonb))
  loop
    if v_par.tipo not in ('single','duplo','triplo') then
      raise exception 'Tipo de quarto invalido: %', v_par.tipo using errcode='22023';
    end if;
    if coalesce(v_par.qtd,0) > 0 then
      insert into cota_quartos (cota_id, tipo, quantidade)
      values (v_cota, v_par.tipo, v_par.qtd);
      v_total := v_total + v_par.qtd;
    end if;
  end loop;

  -- mantem as colunas antigas coerentes para quem ainda as le
  update cotas set quartos_incluidos = v_total where id = v_cota;

  return jsonb_build_object('ok', true, 'id', v_cota, 'total_quartos', v_total);
end;
$$;


ALTER FUNCTION "gestao"."admin_salvar_cota"("p_evento_slug" "text", "p_nome" "text", "p_ordem" integer, "p_quartos" "jsonb", "p_vagas_mesa" integer, "p_reuniao" boolean, "p_jantar" boolean, "p_prazo_indicacao" "date", "p_janela_horas" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_salvar_evento"("p_slug" "text", "p_nome" "text", "p_local" "text" DEFAULT NULL::"text", "p_data_inicio" "date" DEFAULT NULL::"date", "p_data_fim" "date" DEFAULT NULL::"date", "p_status" "text" DEFAULT 'rascunho'::"text", "p_prazo_contrato" "date" DEFAULT NULL::"date", "p_prazo_rooming" "date" DEFAULT NULL::"date", "p_prazo_cancelamento" "date" DEFAULT NULL::"date", "p_sympla_event_id" "text" DEFAULT NULL::"text", "p_cota_unica" boolean DEFAULT false, "p_escolha_abre_em" timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_slug text; v_id uuid; v_cotas int;
begin
  perform _exige_admin();

  v_slug := trim(both '-' from regexp_replace(
    lower(unaccent('unaccent', coalesce(trim(p_slug),''))), '[^a-z0-9]+','-','g'));

  if v_slug = '' then
    raise exception 'Informe o identificador do evento' using errcode='22023';
  end if;
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome do evento' using errcode='22023';
  end if;
  if p_status not in ('rascunho','aberto','encerrado') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;
  if p_data_inicio is not null and p_data_fim is not null
     and p_data_fim < p_data_inicio then
    raise exception 'A data final e anterior a inicial' using errcode='22023';
  end if;

  -- Virar cota unica com varias cotas ja criadas deixaria a fila de
  -- escolha sem sentido, entao o caminho e limpar as cotas antes.
  if p_cota_unica then
    select count(*) into v_cotas from cotas c
    join eventos e on e.id = c.evento_id
    where e.slug = v_slug;
    if v_cotas > 1 then
      raise exception
        'Este evento tem % cotas. Remova-as antes de marcar como cota unica.', v_cotas
        using errcode='22023';
    end if;
  end if;

  insert into eventos (slug, nome, local, data_inicio, data_fim, status,
                       prazo_contrato, prazo_rooming, prazo_cancelamento,
                       sympla_event_id, cota_unica, escolha_abre_em)
  values (v_slug, trim(p_nome), p_local, p_data_inicio, p_data_fim, p_status,
          p_prazo_contrato, p_prazo_rooming, p_prazo_cancelamento,
          p_sympla_event_id, coalesce(p_cota_unica,false), p_escolha_abre_em)
  on conflict (slug) do update set
    nome = excluded.nome, local = excluded.local,
    data_inicio = excluded.data_inicio, data_fim = excluded.data_fim,
    status = excluded.status,
    prazo_contrato = excluded.prazo_contrato,
    prazo_rooming = excluded.prazo_rooming,
    prazo_cancelamento = excluded.prazo_cancelamento,
    sympla_event_id = coalesce(excluded.sympla_event_id, eventos.sympla_event_id),
    cota_unica = excluded.cota_unica,
    escolha_abre_em = excluded.escolha_abre_em
  returning id into v_id;

  -- Evento de cota unica ja nasce com a cota pronta: sem ela o
  -- patrocinador nao consegue ser cadastrado.
  if coalesce(p_cota_unica,false) then
    insert into cotas (evento_id, nome, ordem_prioridade, quartos_incluidos,
                       tipo_quarto_padrao, vagas_mesa_redonda,
                       tem_reuniao_exclusiva, tem_jantar)
    values (v_id, 'Única', 1, 0, 'duplo', 0, false, true)
    on conflict (evento_id, nome) do nothing;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'slug', v_slug,
                            'cota_unica', coalesce(p_cota_unica,false));
end;
$$;


ALTER FUNCTION "gestao"."admin_salvar_evento"("p_slug" "text", "p_nome" "text", "p_local" "text", "p_data_inicio" "date", "p_data_fim" "date", "p_status" "text", "p_prazo_contrato" "date", "p_prazo_rooming" "date", "p_prazo_cancelamento" "date", "p_sympla_event_id" "text", "p_cota_unica" boolean, "p_escolha_abre_em" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_salvar_membro"("p_email" "text", "p_nome" "text" DEFAULT NULL::"text", "p_role" "text" DEFAULT 'staff'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_id uuid;
begin
  perform _exige_admin();

  if coalesce(trim(p_email),'') = '' then
    raise exception 'Informe o e-mail' using errcode = '22023';
  end if;
  if p_role not in ('admin','staff') then
    raise exception 'Perfil invalido: %', p_role using errcode = '22023';
  end if;

  insert into admins (email, nome, role, ativo)
  values (lower(trim(p_email)), p_nome, p_role, true)
  on conflict (email_norm) do update
    set nome  = coalesce(excluded.nome, admins.nome),
        role  = excluded.role,
        ativo = true
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;


ALTER FUNCTION "gestao"."admin_salvar_membro"("p_email" "text", "p_nome" "text", "p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_salvar_patrocinador"("p_evento_slug" "text", "p_empresa" "text", "p_cota_nome" "text" DEFAULT NULL::"text", "p_cnpj" "text" DEFAULT NULL::"text", "p_segmento" "text" DEFAULT NULL::"text", "p_o_que_vende" "text" DEFAULT NULL::"text", "p_quartos_extras" integer DEFAULT 0, "p_vagas_mesa_override" integer DEFAULT NULL::integer, "p_status" "text" DEFAULT 'ativo'::"text", "p_site" "text" DEFAULT NULL::"text", "p_resumo" "text" DEFAULT NULL::"text", "p_natureza" "text" DEFAULT NULL::"text", "p_cidade" "text" DEFAULT NULL::"text", "p_estado" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_evento uuid; v_cota uuid; v_id uuid;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if coalesce(trim(p_empresa),'') = '' then
    raise exception 'Informe o nome da empresa' using errcode='22023';
  end if;

  if p_cota_nome is not null and trim(p_cota_nome) <> '' then
    select id into v_cota from cotas
     where evento_id = v_evento and lower(nome) = lower(trim(p_cota_nome));
    if v_cota is null then
      raise exception 'Cota "%" nao existe neste evento', p_cota_nome
        using errcode='P0002';
    end if;
  end if;

  insert into patrocinadores (evento_id, cota_id, empresa, cnpj, segmento,
                              o_que_vende, quartos_extras_cota,
                              vagas_mesa_override, status,
                              site, resumo, natureza, cidade, estado)
  values (v_evento, v_cota, trim(p_empresa), p_cnpj, p_segmento,
          p_o_que_vende, coalesce(p_quartos_extras,0),
          p_vagas_mesa_override, p_status,
          p_site, p_resumo, p_natureza, p_cidade, p_estado)
  on conflict (evento_id, lower(empresa)) do update set
    cota_id = coalesce(excluded.cota_id, patrocinadores.cota_id),
    cnpj = coalesce(excluded.cnpj, patrocinadores.cnpj),
    segmento = coalesce(excluded.segmento, patrocinadores.segmento),
    o_que_vende = coalesce(excluded.o_que_vende, patrocinadores.o_que_vende),
    quartos_extras_cota = excluded.quartos_extras_cota,
    vagas_mesa_override = excluded.vagas_mesa_override,
    status = excluded.status,
    site = coalesce(excluded.site, patrocinadores.site),
    resumo = coalesce(excluded.resumo, patrocinadores.resumo),
    natureza = coalesce(excluded.natureza, patrocinadores.natureza),
    cidade = coalesce(excluded.cidade, patrocinadores.cidade),
    estado = coalesce(excluded.estado, patrocinadores.estado)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;


ALTER FUNCTION "gestao"."admin_salvar_patrocinador"("p_evento_slug" "text", "p_empresa" "text", "p_cota_nome" "text", "p_cnpj" "text", "p_segmento" "text", "p_o_que_vende" "text", "p_quartos_extras" integer, "p_vagas_mesa_override" integer, "p_status" "text", "p_site" "text", "p_resumo" "text", "p_natureza" "text", "p_cidade" "text", "p_estado" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_salvar_preco"("p_evento_slug" "text", "p_item" "text", "p_valor" numeric, "p_descricao" "text" DEFAULT NULL::"text", "p_idade_min" integer DEFAULT NULL::integer, "p_idade_max" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_evento uuid; v_item text; v_conflito text;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;

  v_item := trim(both '_' from regexp_replace(
    lower(unaccent('unaccent', coalesce(trim(p_item),''))), '[^a-z0-9]+','_','g'));

  if v_item = '' then
    raise exception 'Informe o item' using errcode='22023';
  end if;
  if p_valor is null or p_valor < 0 then
    raise exception 'Valor invalido' using errcode='22023';
  end if;
  if p_idade_min is not null and p_idade_max is not null
     and p_idade_max < p_idade_min then
    raise exception 'A idade final e menor que a inicial' using errcode='22023';
  end if;

  -- Faixas que se cruzam tornam o preco ambiguo: "0 a 11" e "6 a 12"
  -- deixariam a crianca de 8 anos com dois valores possiveis.
  if p_idade_min is not null or p_idade_max is not null then
    select _rotulo_faixa(pr.idade_min, pr.idade_max) into v_conflito
    from precos pr
    where pr.evento_id = v_evento and pr.item = v_item
      and (pr.idade_min is not null or pr.idade_max is not null)
      and coalesce(pr.idade_min,0)   <= coalesce(p_idade_max,999)
      and coalesce(pr.idade_max,999) >= coalesce(p_idade_min,0)
      and not (coalesce(pr.idade_min,-1) = coalesce(p_idade_min,-1)
               and coalesce(pr.idade_max,999) = coalesce(p_idade_max,999))
    limit 1;

    if v_conflito is not null then
      raise exception 'Esta faixa se sobrepõe à faixa%', v_conflito
        using errcode='23505';
    end if;
  end if;

  insert into precos (evento_id, item, descricao, valor, idade_min, idade_max)
  values (v_evento, v_item, p_descricao, p_valor, p_idade_min, p_idade_max)
  on conflict (evento_id, item, coalesce(idade_min,-1), coalesce(idade_max,999))
  do update set valor = excluded.valor,
                descricao = coalesce(excluded.descricao, precos.descricao);

  return jsonb_build_object('ok', true, 'item', v_item,
                            'faixa', _rotulo_faixa(p_idade_min, p_idade_max));
end;
$$;


ALTER FUNCTION "gestao"."admin_salvar_preco"("p_evento_slug" "text", "p_item" "text", "p_valor" numeric, "p_descricao" "text", "p_idade_min" integer, "p_idade_max" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_salvar_prospeccao"("p_evento_slug" "text", "p_sessao_id" "uuid", "p_itens" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid; v_patro uuid; v_item jsonb; v_n int := 0;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;

  if p_sessao_id is not null then
    select patrocinador_id into v_patro from sessoes where id = p_sessao_id;
  end if;

  -- substitui a rodada anterior da mesma sessao: a tela mostra uma
  -- lista de cada vez, e acumular geraria duplicata a cada reanalise
  delete from prospeccoes
   where evento_id = v_evento
     and sessao_id is not distinct from p_sessao_id
     and status = 'sugerido';

  for v_item in select * from jsonb_array_elements(coalesce(p_itens,'[]'::jsonb))
  loop
    insert into prospeccoes (evento_id, sessao_id, patrocinador_id,
                             gestor_id, empresa, score, natureza,
                             justificativa, status, criado_por)
    values (v_evento, p_sessao_id, v_patro,
            nullif(v_item ->> 'gestor_id','')::uuid,
            v_item ->> 'empresa',
            nullif(v_item ->> 'score','')::numeric,
            nullif(v_item ->> 'natureza',''),
            nullif(v_item ->> 'justificativa',''),
            case when (v_item ->> 'aprovado')::boolean then 'aprovado'
                 else 'sugerido' end,
            auth.jwt() ->> 'email');
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'salvos', v_n);
end;
$$;


ALTER FUNCTION "gestao"."admin_salvar_prospeccao"("p_evento_slug" "text", "p_sessao_id" "uuid", "p_itens" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_salvar_sessao"("p_evento_slug" "text", "p_patrocinador_id" "uuid", "p_tipo" "text", "p_data" "date" DEFAULT NULL::"date", "p_horario" time without time zone DEFAULT NULL::time without time zone, "p_local" "text" DEFAULT NULL::"text", "p_vagas" integer DEFAULT NULL::integer, "p_sessao_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_evento uuid; v_vagas int; v_id uuid; v_ja int;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if p_tipo not in ('mesa_redonda','reuniao_exclusiva','jantar') then
    raise exception 'Tipo de sessao invalido' using errcode='22023';
  end if;

  -- vagas em branco herdam a cota do patrocinador
  v_vagas := p_vagas;
  if v_vagas is null then
    select coalesce(p.vagas_mesa_override, c.vagas_mesa_redonda)
      into v_vagas
    from patrocinadores p left join cotas c on c.id = p.cota_id
    where p.id = p_patrocinador_id;
  end if;
  v_vagas := coalesce(v_vagas, 0);

  if p_sessao_id is not null then
    -- reduzir vagas abaixo de quem ja foi escolhido deixaria a sessao
    -- em estado impossivel
    select count(*) into v_ja from sessao_convidados
     where sessao_id = p_sessao_id and status = 'confirmado';
    if v_vagas < v_ja then
      raise exception 'Ja ha % convidado(s) confirmado(s); as vagas nao podem ser menos que isso', v_ja
        using errcode='22023';
    end if;

    update sessoes set tipo = p_tipo, data = p_data, horario = p_horario,
                       local = p_local, vagas = v_vagas
     where id = p_sessao_id
    returning id into v_id;
  else
    insert into sessoes (evento_id, patrocinador_id, tipo, data, horario,
                         local, vagas)
    values (v_evento, p_patrocinador_id, p_tipo, p_data, p_horario,
            p_local, v_vagas)
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'vagas', v_vagas);
end;
$$;


ALTER FUNCTION "gestao"."admin_salvar_sessao"("p_evento_slug" "text", "p_patrocinador_id" "uuid", "p_tipo" "text", "p_data" "date", "p_horario" time without time zone, "p_local" "text", "p_vagas" integer, "p_sessao_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."admin_salvar_usuario_patro"("p_patrocinador_id" "uuid", "p_email" "text", "p_nome" "text" DEFAULT NULL::"text", "p_telefone" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_admin();

  if coalesce(trim(p_email),'') = '' then
    raise exception 'Informe o e-mail' using errcode='22023';
  end if;

  insert into usuarios_patrocinador (patrocinador_id, email, nome, telefone, ativo)
  values (p_patrocinador_id, lower(trim(p_email)), p_nome, p_telefone, true)
  on conflict (patrocinador_id, email_norm) do update set
    nome = coalesce(excluded.nome, usuarios_patrocinador.nome),
    telefone = coalesce(excluded.telefone, usuarios_patrocinador.telefone),
    ativo = true;

  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."admin_salvar_usuario_patro"("p_patrocinador_id" "uuid", "p_email" "text", "p_nome" "text", "p_telefone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."checkin_cadastrar"("p_evento_slug" "text", "p_nome" "text", "p_empresa" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text", "p_telefone" "text" DEFAULT NULL::"text", "p_cargo" "text" DEFAULT NULL::"text", "p_categoria" "text" DEFAULT 'PROTAGONISTA'::"text", "p_local" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid; v_gestor uuid; v_part uuid;
  v_key text; v_reaproveitado boolean := false;
begin
  perform _exige_staff();

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome' using errcode='22023';
  end if;

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;

  if coalesce(trim(p_email),'') <> '' then
    select g.id into v_gestor from gestores g
     where g.email_norm = norm_doc(p_email);
    v_reaproveitado := v_gestor is not null;
  end if;

  if v_gestor is null then
    insert into gestores (nome, email, empresa, cargo, telefone, perfil, origem)
    values (trim(p_nome),
            coalesce(nullif(lower(trim(p_email)),''),
                     'avulso.' || replace(gen_random_uuid()::text,'-','')
                     || '@interno.ciocerrado.com.br'),
            p_empresa, p_cargo, p_telefone,
            coalesce(nullif(trim(p_categoria),''), 'PROTAGONISTA'), 'manual')
    returning id into v_gestor;
  else
    -- completa o que faltava sem sobrescrever o que ja existia
    update gestores set
      empresa  = coalesce(empresa, p_empresa),
      telefone = coalesce(telefone, p_telefone),
      cargo    = coalesce(cargo, p_cargo)
    where id = v_gestor;
  end if;

  select pa.id into v_part from participantes pa
   where pa.evento_id = v_evento and pa.gestor_id = v_gestor;

  if v_part is null then
    insert into participantes (evento_id, gestor_id, status, origem,
                               aprovado_em, aprovado_por)
    values (v_evento, v_gestor, 'aprovado', 'manual', now(),
            auth.jwt() ->> 'email')
    returning id into v_part;
  else
    update participantes set status = 'aprovado'
     where id = v_part and status <> 'aprovado';
  end if;

  v_key := 'participante:' || v_part::text;

  -- registra o check-in na mesma chamada: a recepcao nao precisa
  -- cadastrar, procurar de novo e clicar outra vez
  return checkin_registrar(p_evento_slug, v_key, p_local)
         || jsonb_build_object('cadastrado', true,
                               'gestor_reaproveitado', v_reaproveitado);
end;
$$;


ALTER FUNCTION "gestao"."checkin_cadastrar"("p_evento_slug" "text", "p_nome" "text", "p_empresa" "text", "p_email" "text", "p_telefone" "text", "p_cargo" "text", "p_categoria" "text", "p_local" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."checkin_desfazer"("p_checkin_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_n int;
begin
  perform _exige_staff();

  update checkins
     set desfeito_em = now(),
         desfeito_por = auth.jwt() ->> 'email'
   where id = p_checkin_id and desfeito_em is null;

  -- sem isso, desfazer duas vezes (ou um id errado) devolve sucesso
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'Check-in nao encontrado ou ja desfeito.' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."checkin_desfazer"("p_checkin_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."checkin_listar"("p_evento_slug" "text", "p_termo" "text" DEFAULT NULL::"text", "p_so_pendentes" boolean DEFAULT false, "p_limite" integer DEFAULT 300) RETURNS TABLE("pessoa_key" "text", "nome" "text", "empresa" "text", "categoria" "text", "quarto" "text", "checkin_id" "uuid", "registrado_em" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_termo text;
begin
  perform _exige_staff();
  v_termo := nullif(trim(coalesce(p_termo,'')), '');

  return query
    select v.pessoa_key, v.nome, v.empresa, v.categoria, v.quarto,
           c.id, c.registrado_em
    from v_esperados v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    left join checkins c on c.pessoa_key = v.pessoa_key
                        and c.evento_id = v.evento_id
                        and c.desfeito_em is null
    where (v_termo is null
           or v.nome ilike '%'||v_termo||'%'
           or coalesce(v.empresa,'') ilike '%'||v_termo||'%'
           or coalesce(v.email,'') ilike '%'||v_termo||'%')
      and (not p_so_pendentes or c.id is null)
    order by (c.id is not null), v.nome
    limit p_limite;
end;
$$;


ALTER FUNCTION "gestao"."checkin_listar"("p_evento_slug" "text", "p_termo" "text", "p_so_pendentes" boolean, "p_limite" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."checkin_registrar"("p_evento_slug" "text", "p_pessoa_key" "text", "p_local" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid; v_nome text; v_email text; v_patro uuid;
  v_ocupante uuid; v_ja timestamptz; v_id uuid;
begin
  perform _exige_staff();

  select v.evento_id, v.nome, v.email, v.patrocinador_id
    into v_evento, v_nome, v_email, v_patro
  from v_esperados v
  join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
  where v.pessoa_key = p_pessoa_key;

  if v_evento is null then
    raise exception 'Pessoa nao encontrada neste evento' using errcode='P0002';
  end if;

  if p_pessoa_key like 'ocupante:%' then
    v_ocupante := substring(p_pessoa_key from 10)::uuid;
  end if;

  select c.registrado_em into v_ja from checkins c
   where c.pessoa_key = p_pessoa_key and c.evento_id = v_evento
     and c.desfeito_em is null
   limit 1;

  if v_ja is not null then
    return jsonb_build_object('ok', true, 'ja_estava', true,
                              'nome', v_nome, 'registrado_em', v_ja);
  end if;

  insert into checkins (evento_id, patrocinador_id, ocupante_id, pessoa_key,
                        nome, email, local, registrado_por)
  values (v_evento, v_patro, v_ocupante, p_pessoa_key, v_nome, v_email,
          p_local, auth.jwt() ->> 'email')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'ja_estava', false,
                            'id', v_id, 'nome', v_nome);
end;
$$;


ALTER FUNCTION "gestao"."checkin_registrar"("p_evento_slug" "text", "p_pessoa_key" "text", "p_local" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."checkin_resumo"("p_evento_slug" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_esperados int; v_feitos int;
begin
  perform _exige_staff();

  select count(*) into v_esperados
  from v_esperados v
  join eventos e on e.id = v.evento_id and e.slug = p_evento_slug;

  select count(*) into v_feitos
  from checkins c
  join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
  where c.desfeito_em is null;

  return jsonb_build_object(
    'esperados', v_esperados,
    'feitos',    v_feitos,
    'pendentes', greatest(v_esperados - v_feitos, 0));
end;
$$;


ALTER FUNCTION "gestao"."checkin_resumo"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  select exists (
    select 1 from admins
    where email_norm = norm_doc(auth.jwt() ->> 'email')
      and role = 'admin' and ativo
  );
$$;


ALTER FUNCTION "gestao"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."is_staff"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  select exists (
    select 1 from admins
    where email_norm = norm_doc(auth.jwt() ->> 'email')
      and ativo
  );
$$;


ALTER FUNCTION "gestao"."is_staff"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."jantar_avulso"("p_jantar_id" "uuid", "p_nome" "text", "p_empresa" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text", "p_telefone" "text" DEFAULT NULL::"text", "p_cargo" "text" DEFAULT NULL::"text", "p_rotulo" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_gestor uuid; v_cap int; v_ocupados int; v_reaproveitado boolean := false;
begin
  perform _exige_staff();

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome' using errcode='22023';
  end if;

  select capacidade into v_cap from jantares where id = p_jantar_id;
  if v_cap is null then
    raise exception 'Jantar nao encontrado' using errcode='P0002';
  end if;

  select count(*) into v_ocupados from jantar_convidados
   where jantar_id = p_jantar_id and status in ('confirmado','compareceu');

  if v_ocupados >= v_cap then
    raise exception 'O jantar já tem % de % vaga(s) ocupada(s)', v_ocupados, v_cap
      using errcode='22023';
  end if;

  if coalesce(trim(p_email),'') <> '' then
    select g.id into v_gestor from gestores g where g.email_norm = norm_doc(p_email);
    v_reaproveitado := v_gestor is not null;
  end if;

  if v_gestor is null then
    insert into gestores (nome, email, empresa, cargo, telefone, perfil, origem)
    values (trim(p_nome),
            coalesce(nullif(lower(trim(p_email)),''),
                     'avulso.' || replace(gen_random_uuid()::text,'-','')
                     || '@interno.ciocerrado.com.br'),
            p_empresa, p_cargo, p_telefone,
            coalesce(nullif(trim(p_rotulo),''), 'CONVIDADO'), 'manual')
    returning id into v_gestor;
  end if;

  insert into jantar_convidados (jantar_id, gestor_id, empresa, origem,
                                 rotulo, status)
  values (p_jantar_id, v_gestor, p_empresa, 'avulso',
          nullif(trim(p_rotulo),''), 'confirmado')
  on conflict (jantar_id, gestor_id) do update set status = 'confirmado';

  return jsonb_build_object('ok', true, 'gestor_reaproveitado', v_reaproveitado);
end;
$$;


ALTER FUNCTION "gestao"."jantar_avulso"("p_jantar_id" "uuid", "p_nome" "text", "p_empresa" "text", "p_email" "text", "p_telefone" "text", "p_cargo" "text", "p_rotulo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."jantar_base"("p_jantar_id" "uuid", "p_excluir_fornecedores" boolean DEFAULT true, "p_excluir_convidados" boolean DEFAULT true, "p_limite" integer DEFAULT 500) RETURNS TABLE("empresa" "text", "segmento" "text", "faturamento" "text", "funcionarios" "text", "cidade" "text", "estado" "text", "cnpj" "text", "exec1_id" "uuid", "exec1_nome" "text", "exec1_cargo" "text", "exec1_email" "text", "exec1_telefone" "text", "exec2_id" "uuid", "exec2_nome" "text", "exec2_cargo" "text", "exec2_email" "text", "exec2_telefone" "text", "contatos" bigint, "ja_convidado_em" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();

  return query
  with
  ja_novo as (
    select lower(trim(g.empresa)) as empresa,
           string_agg(distinct to_char(j.data,'DD/MM/YYYY'), ', ') as quando
    from jantar_convidados jc
    join jantares j on j.id = jc.jantar_id
    join gestores g on g.id = jc.gestor_id
    where jc.status in ('confirmado','compareceu')
      and coalesce(trim(g.empresa),'') <> ''
    group by lower(trim(g.empresa))
  ),
  ja_antigo as (
    select lower(trim(g.empresa)) as empresa,
           string_agg(distinct ev.nome, ', ') as quando
    from sessao_convidados sc
    join sessoes s on s.id = sc.sessao_id and s.tipo = 'jantar'
    join eventos ev on ev.id = s.evento_id
    join participantes pa on pa.id = sc.participante_id
    join gestores g on g.id = pa.gestor_id
    where sc.status = 'confirmado'
      and coalesce(trim(g.empresa),'') <> ''
    group by lower(trim(g.empresa))
  ),
  ja as (
    -- concat_ws de dois nulos vira string vazia, nao nulo — e o filtro
    -- "j.empresa is null" la embaixo depende de null para funcionar.
    -- nullif fecha essa brecha.
    select coalesce(n.empresa, a.empresa) as empresa,
           nullif(concat_ws(', ', n.quando, a.quando), '') as quando
    from ja_novo n full outer join ja_antigo a on a.empresa = n.empresa
  ),
  neste as (
    -- ja tem linha neste jantar (qualquer status): nao sugere de novo
    select lower(trim(g.empresa)) as empresa
    from jantar_convidados jc
    join gestores g on g.id = jc.gestor_id
    where jc.jantar_id = p_jantar_id
  ),
  ranqueado as (
    select g.*,
           row_number() over (
             partition by lower(trim(g.empresa))
             order by _rank_pos(g.posicao_gestor), _rank_cargo(g.cargo), g.nome) as pos,
           count(*) over (partition by lower(trim(g.empresa))) as n
    from gestores g
    where g.ativo
      and coalesce(trim(g.empresa),'') <> ''
      and coalesce(trim(g.nome),'') <> ''
      and (not p_excluir_fornecedores
           or coalesce(upper(unaccent('unaccent', g.perfil)),'')
              not like '%FORNECEDOR%')
  )
  select
    a.empresa, a.segmento, a.faturamento, a.funcionarios,
    a.cidade, a.estado, a.cnpj,
    a.id, a.nome, a.cargo, a.email, a.telefone,
    b.id, b.nome, b.cargo, b.email, b.telefone,
    a.n,
    j.quando
  from ranqueado a
  left join ranqueado b
    on lower(trim(b.empresa)) = lower(trim(a.empresa)) and b.pos = 2
  left join ja j on j.empresa = lower(trim(a.empresa))
  left join neste ne on ne.empresa = lower(trim(a.empresa))
  where a.pos = 1
    and ne.empresa is null
    and (not p_excluir_convidados or j.empresa is null)
  order by a.empresa
  limit p_limite;
end;
$$;


ALTER FUNCTION "gestao"."jantar_base"("p_jantar_id" "uuid", "p_excluir_fornecedores" boolean, "p_excluir_convidados" boolean, "p_limite" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."jantar_convidados_listar"("p_jantar_id" "uuid") RETURNS TABLE("id" "uuid", "gestor_id" "uuid", "nome" "text", "empresa" "text", "cargo" "text", "email" "text", "telefone" "text", "origem" "text", "rotulo" "text", "score" numeric, "natureza" "text", "justificativa" "text", "status" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select jc.id, jc.gestor_id, g.nome, coalesce(jc.empresa, g.empresa),
           g.cargo, g.email, g.telefone, jc.origem, jc.rotulo,
           jc.score, jc.natureza, jc.justificativa, jc.status
    from jantar_convidados jc
    join gestores g on g.id = jc.gestor_id
    where jc.jantar_id = p_jantar_id
    order by
      case jc.status when 'compareceu' then 0 when 'confirmado' then 1
                     when 'convidado' then 2 when 'sugerido' then 3 else 4 end,
      g.empresa, g.nome;
end;
$$;


ALTER FUNCTION "gestao"."jantar_convidados_listar"("p_jantar_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."jantar_empresas_sem_convite"("p_limite" integer DEFAULT 200) RETURNS TABLE("empresa" "text", "segmento" "text", "contatos" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    with convidadas as (
      select distinct lower(trim(g.empresa)) as empresa
      from jantar_convidados jc
      join gestores g on g.id = jc.gestor_id
      where jc.status in ('confirmado','compareceu')

      union

      select distinct lower(trim(g.empresa))
      from sessao_convidados sc
      join sessoes s on s.id = sc.sessao_id and s.tipo = 'jantar'
      join participantes pa on pa.id = sc.participante_id
      join gestores g on g.id = pa.gestor_id
      where sc.status = 'confirmado'
    )
    select g.empresa, min(g.segmento), count(*)
    from gestores g
    where g.ativo and coalesce(trim(g.empresa),'') <> ''
      and not exists (select 1 from convidadas c where c.empresa = lower(trim(g.empresa)))
    group by g.empresa
    order by count(*) desc, g.empresa
    limit p_limite;
end;
$$;


ALTER FUNCTION "gestao"."jantar_empresas_sem_convite"("p_limite" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."jantar_estatisticas_gestores"("p_limite" integer DEFAULT 200) RETURNS TABLE("nome" "text", "empresa" "text", "vezes" integer, "ultima_vez" "date")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    with tudo as (
      select jc.gestor_id, j.data
      from jantar_convidados jc
      join jantares j on j.id = jc.jantar_id
      where jc.status in ('confirmado','compareceu')

      union all

      select pa.gestor_id, s.data
      from sessao_convidados sc
      join sessoes s on s.id = sc.sessao_id and s.tipo = 'jantar'
      join participantes pa on pa.id = sc.participante_id
      where sc.status = 'confirmado'
    )
    select g.nome, g.empresa, count(*)::int, max(t.data)
    from tudo t
    join gestores g on g.id = t.gestor_id
    group by g.id, g.nome, g.empresa
    order by count(*) desc, g.nome
    limit p_limite;
end;
$$;


ALTER FUNCTION "gestao"."jantar_estatisticas_gestores"("p_limite" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."jantar_listar"("p_status" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "data" "date", "horario" time without time zone, "local" "text", "patrocinador" "text", "capacidade" integer, "status" "text", "confirmados" bigint, "compareceram" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select j.id, j.data, j.horario, j.local, j.patrocinador_nome,
           j.capacidade, j.status,
           (select count(*) from jantar_convidados c
             where c.jantar_id = j.id and c.status in ('confirmado','compareceu')),
           (select count(*) from jantar_convidados c
             where c.jantar_id = j.id and c.status = 'compareceu')
    from jantares j
    where p_status is null or j.status = p_status
    order by j.data desc nulls last, j.created_at desc;
end;
$$;


ALTER FUNCTION "gestao"."jantar_listar"("p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."jantar_marcar_convidado"("p_id" "uuid", "p_status" "text", "p_observacao" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_jantar uuid; v_cap int; v_ocupados int;
begin
  perform _exige_staff();

  if p_status not in ('sugerido','convidado','confirmado','recusado','compareceu') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;

  select jc.jantar_id into v_jantar from jantar_convidados jc where jc.id = p_id;
  if v_jantar is null then
    raise exception 'Convidado nao encontrado' using errcode='P0002';
  end if;

  if p_status in ('confirmado','compareceu') then
    select capacidade into v_cap from jantares where id = v_jantar;
    select count(*) into v_ocupados from jantar_convidados
     where jantar_id = v_jantar and status in ('confirmado','compareceu')
       and id <> p_id;
    if v_ocupados >= v_cap then
      raise exception 'O jantar já está com todas as % vaga(s) ocupadas', v_cap
        using errcode='22023';
    end if;
  end if;

  update jantar_convidados set
    status = p_status,
    observacao = coalesce(p_observacao, observacao)
  where id = p_id;

  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."jantar_marcar_convidado"("p_id" "uuid", "p_status" "text", "p_observacao" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."jantar_obter"("p_id" "uuid") RETURNS TABLE("id" "uuid", "data" "date", "horario" time without time zone, "local" "text", "patrocinador_nome" "text", "patrocinador_site" "text", "perfil_convidado" "text", "observacoes" "text", "abrangencia" "text", "capacidade" integer, "status" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select j.id, j.data, j.horario, j.local, j.patrocinador_nome,
           j.patrocinador_site, j.perfil_convidado, j.observacoes,
           j.abrangencia, j.capacidade, j.status
    from jantares j where j.id = p_id;
end;
$$;


ALTER FUNCTION "gestao"."jantar_obter"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."jantar_remover"("p_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_n int;
begin
  perform _exige_admin();
  select count(*) into v_n from jantar_convidados
   where jantar_id = p_id and status in ('confirmado','compareceu');
  if v_n > 0 then
    raise exception 'Há % convidado(s) confirmado(s) neste jantar', v_n
      using errcode='23503';
  end if;
  delete from jantares where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."jantar_remover"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."jantar_remover_convidado"("p_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_admin();
  delete from jantar_convidados where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."jantar_remover_convidado"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."jantar_salvar"("p_patrocinador_nome" "text", "p_id" "uuid" DEFAULT NULL::"uuid", "p_data" "date" DEFAULT NULL::"date", "p_horario" time without time zone DEFAULT NULL::time without time zone, "p_local" "text" DEFAULT NULL::"text", "p_patrocinador_site" "text" DEFAULT NULL::"text", "p_perfil_convidado" "text" DEFAULT NULL::"text", "p_observacoes" "text" DEFAULT NULL::"text", "p_abrangencia" "text" DEFAULT NULL::"text", "p_capacidade" integer DEFAULT 8, "p_status" "text" DEFAULT 'planejado'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_id uuid; v_ja int;
begin
  perform _exige_admin();

  if coalesce(trim(p_patrocinador_nome),'') = '' then
    raise exception 'Informe o patrocinador' using errcode='22023';
  end if;
  if p_status not in ('planejado','confirmado','realizado','cancelado') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;

  if p_id is not null then
    -- capacidade nao pode ficar menor que quem ja esta confirmado
    select count(*) into v_ja from jantar_convidados
     where jantar_id = p_id and status in ('confirmado','compareceu');
    if coalesce(p_capacidade,8) < v_ja then
      raise exception 'Já há % confirmado(s); a capacidade não pode ser menor que isso', v_ja
        using errcode='22023';
    end if;

    update jantares set
      data = p_data, horario = p_horario, local = p_local,
      patrocinador_nome = trim(p_patrocinador_nome),
      patrocinador_site = p_patrocinador_site,
      perfil_convidado = p_perfil_convidado,
      observacoes = p_observacoes, abrangencia = p_abrangencia,
      capacidade = coalesce(p_capacidade,8), status = p_status
    where id = p_id
    returning id into v_id;
  else
    insert into jantares (data, horario, local, patrocinador_nome,
                          patrocinador_site, perfil_convidado, observacoes,
                          abrangencia, capacidade, status, criado_por)
    values (p_data, p_horario, p_local, trim(p_patrocinador_nome),
            p_patrocinador_site, p_perfil_convidado, p_observacoes,
            p_abrangencia, coalesce(p_capacidade,8), p_status,
            auth.jwt() ->> 'email')
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;


ALTER FUNCTION "gestao"."jantar_salvar"("p_patrocinador_nome" "text", "p_id" "uuid", "p_data" "date", "p_horario" time without time zone, "p_local" "text", "p_patrocinador_site" "text", "p_perfil_convidado" "text", "p_observacoes" "text", "p_abrangencia" "text", "p_capacidade" integer, "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."jantar_salvar_selecao"("p_jantar_id" "uuid", "p_itens" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_item jsonb; v_n int := 0;
begin
  perform _exige_admin();

  for v_item in select * from jsonb_array_elements(coalesce(p_itens,'[]'::jsonb))
  loop
    if not (v_item ->> 'manter')::boolean then continue; end if;

    insert into jantar_convidados (jantar_id, gestor_id, empresa, origem,
                                   score, natureza, justificativa, status)
    values (p_jantar_id, (v_item ->> 'gestor_id')::uuid,
            v_item ->> 'empresa', 'prospeccao',
            nullif(v_item ->> 'score','')::numeric,
            v_item ->> 'natureza', v_item ->> 'justificativa', 'convidado')
    on conflict (jantar_id, gestor_id) do update set
      score = excluded.score, natureza = excluded.natureza,
      justificativa = excluded.justificativa;

    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'salvos', v_n);
end;
$$;


ALTER FUNCTION "gestao"."jantar_salvar_selecao"("p_jantar_id" "uuid", "p_itens" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."listar_cotas"("p_evento_slug" "text") RETURNS TABLE("nome" "text", "ordem_prioridade" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  select c.nome, c.ordem_prioridade
  from cotas c
  join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
  order by c.ordem_prioridade;
$$;


ALTER FUNCTION "gestao"."listar_cotas"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."meus_patrocinadores"() RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  select patrocinador_id from usuarios_patrocinador
  where email_norm = norm_doc(auth.jwt() ->> 'email') and ativo;
$$;


ALTER FUNCTION "gestao"."meus_patrocinadores"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."norm_cpf"("v" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select nullif(regexp_replace(coalesce(v,''), '[^0-9]', '', 'g'), '');
$$;


ALTER FUNCTION "gestao"."norm_cpf"("v" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."norm_doc"("v" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select nullif(
    regexp_replace(lower(unaccent('unaccent', coalesce(v,''))), '[^a-z0-9@._+-]', '', 'g'),
    ''
  );
$$;


ALTER FUNCTION "gestao"."norm_doc"("v" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."part_autocadastro"("p_evento_slug" "text", "p_nome" "text", "p_email" "text", "p_empresa" "text" DEFAULT NULL::"text", "p_cargo" "text" DEFAULT NULL::"text", "p_telefone" "text" DEFAULT NULL::"text", "p_cnpj" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid;
  v_gestor uuid;
  v_part   uuid;
  v_status text;
begin
  if coalesce(trim(p_nome),'') = '' or coalesce(trim(p_email),'') = '' then
    raise exception 'Nome e e-mail sao obrigatorios' using errcode = '22023';
  end if;

  select id into v_evento from eventos
   where slug = p_evento_slug and status = 'aberto';

  if v_evento is null then
    return jsonb_build_object('ok', false, 'motivo', 'evento_fechado');
  end if;

  -- gestor ja existe? aproveita o cadastro e atualiza o que veio vazio
  select id into v_gestor from gestores where email_norm = norm_doc(p_email);

  if v_gestor is null then
    insert into gestores (nome, email, empresa, cargo, telefone, cnpj, origem)
    values (trim(p_nome), lower(trim(p_email)), p_empresa, p_cargo,
            p_telefone, p_cnpj, 'autocadastro')
    returning id into v_gestor;
  else
    update gestores set
      empresa  = coalesce(empresa,  p_empresa),
      cargo    = coalesce(cargo,    p_cargo),
      telefone = coalesce(telefone, p_telefone),
      cnpj     = coalesce(cnpj,     p_cnpj)
    where id = v_gestor;
  end if;

  -- ja inscrito neste evento? nao duplica, so devolve o status atual
  select id, status into v_part, v_status
  from participantes where evento_id = v_evento and gestor_id = v_gestor;

  if v_part is not null then
    return jsonb_build_object('ok', true, 'ja_inscrito', true,
                              'status', v_status);
  end if;

  insert into participantes (evento_id, gestor_id, status, origem)
  values (v_evento, v_gestor, 'pendente', 'autocadastro')
  returning id into v_part;

  insert into notificacoes (evento_id, destinatario, tipo, assunto)
  values (v_evento, lower(trim(p_email)), 'autocadastro_recebido',
          'Recebemos seu cadastro');

  return jsonb_build_object('ok', true, 'ja_inscrito', false,
                            'status', 'pendente');
end;
$$;


ALTER FUNCTION "gestao"."part_autocadastro"("p_evento_slug" "text", "p_nome" "text", "p_email" "text", "p_empresa" "text", "p_cargo" "text", "p_telefone" "text", "p_cnpj" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."part_calcular_fatura"("p_evento_slug" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_part uuid; v_total numeric(12,2); v_fatura uuid;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode='P0002';
  end if;

  v_total := _recalcular_fatura_participante(v_part);

  select id into v_fatura from faturas
   where participante_id = v_part and status = 'estimada';

  return jsonb_build_object(
    'total', coalesce(v_total,0),
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object(
        'descricao', fi.descricao, 'quantidade', fi.quantidade,
        'valor_unit', fi.valor_unit, 'valor_total', fi.valor_total))
      from fatura_itens fi where fi.fatura_id = v_fatura), '[]'::jsonb));
end;
$$;


ALTER FUNCTION "gestao"."part_calcular_fatura"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."part_listar_rooming"("p_evento_slug" "text") RETURNS TABLE("id" "uuid", "nome" "text", "cpf" "text", "data_nascimento" "date", "tipo" "text", "usa_transfer" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_part uuid;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then return; end if;

  return query
    select o.id, o.nome, o.cpf, o.data_nascimento, o.tipo, o.usa_transfer
    from ocupantes o
    join reservas r on r.id = o.reserva_id
    where r.participante_id = v_part and r.status <> 'cancelado'
    order by (o.tipo = 'titular') desc, o.created_at;
end;
$$;


ALTER FUNCTION "gestao"."part_listar_rooming"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."part_meu_status"("p_evento_slug" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_part uuid;
  v_out  jsonb;
begin
  v_part := _meu_participante(p_evento_slug);

  if v_part is null then
    return jsonb_build_object('inscrito', false);
  end if;

  select jsonb_build_object(
    'inscrito',          true,
    'participante_id',   pa.id,
    'nome',              g.nome,
    'empresa',           g.empresa,
    'status_inscricao',  pa.status,
    'status_contrato',   coalesce(ct.status, 'nao_enviado'),
    'contrato_url',      ct.autentique_url,
    -- rooming so abre com inscricao aprovada E contrato assinado
    'rooming_liberado',  (pa.status = 'aprovado'
                          and coalesce(ct.status,'') = 'assinado'),
    'prazo_rooming',     e.prazo_rooming,
    'prazo_contrato',    e.prazo_contrato,
    'reserva_id',        r.id,
    'status_rooming',    coalesce(r.status, 'nao_iniciado')
  ) into v_out
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  join eventos  e on e.id = pa.evento_id
  left join contratos ct on ct.participante_id = pa.id
  left join reservas  r  on r.participante_id = pa.id and r.status <> 'cancelado'
  where pa.id = v_part;

  return v_out;
end;
$$;


ALTER FUNCTION "gestao"."part_meu_status"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."part_minha_fatura"("p_evento_slug" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_part uuid; v_out jsonb;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then return jsonb_build_object('total', 0); end if;

  select jsonb_build_object(
    'total', f.total, 'status', f.status,
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object(
        'descricao', fi.descricao, 'quantidade', fi.quantidade,
        'valor_unit', fi.valor_unit, 'valor_total', fi.valor_total))
      from fatura_itens fi where fi.fatura_id = f.id), '[]'::jsonb))
  into v_out
  from faturas f
  where f.participante_id = v_part and f.status <> 'cancelada'
  order by case f.status when 'emitida' then 1 when 'paga' then 2 else 3 end
  limit 1;

  return coalesce(v_out, jsonb_build_object('total', 0, 'itens', '[]'::jsonb));
end;
$$;


ALTER FUNCTION "gestao"."part_minha_fatura"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."part_previa_fatura"("p_evento_slug" "text", "p_acompanhantes" "jsonb", "p_usa_transfer" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_part uuid; v_evento uuid;
  v_total numeric(12,2) := 0;
  v_item jsonb; v_idade int; v_valor numeric(12,2);
  v_itens jsonb := '[]'::jsonb;
  v_nasc date; v_tipo text; v_transf int := 0;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode='P0002';
  end if;
  select evento_id into v_evento from participantes where id = v_part;

  for v_item in select * from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb))
  loop
    v_nasc := nullif(v_item ->> 'data_nascimento','')::date;
    v_tipo := coalesce(nullif(v_item ->> 'tipo',''), 'adulto');
    v_idade := _idade_no_evento(v_evento, v_nasc);
    v_valor := _preco_item(v_evento, _item_do_ocupante(v_tipo), v_idade);

    v_total := v_total + v_valor;
    v_itens := v_itens || jsonb_build_object(
      'descricao', case when v_tipo = 'crianca' then 'Criança' else 'Acompanhante adulto' end
                 || case when v_idade is not null then ' · ' || v_idade || ' anos' else '' end,
      'valor', v_valor);

    if (v_item ->> 'usa_transfer')::boolean then
      v_valor := _preco_item(v_evento, 'transfer', v_idade);
      v_total := v_total + v_valor;
      v_transf := v_transf + 1;
    end if;
  end loop;

  -- o titular tambem paga transfer e nao vem no payload
  if p_usa_transfer then
    v_valor := _preco_item(v_evento, 'transfer', null);
    v_total := v_total + v_valor;
    v_transf := v_transf + 1;
  end if;

  if v_transf > 0 then
    v_itens := v_itens || jsonb_build_object(
      'descricao', 'Transfer × ' || v_transf, 'valor', null);
  end if;

  return jsonb_build_object('total', v_total, 'itens', v_itens,
                            'transfers', v_transf);
end;
$$;


ALTER FUNCTION "gestao"."part_previa_fatura"("p_evento_slug" "text", "p_acompanhantes" "jsonb", "p_usa_transfer" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."part_salvar_rooming"("p_evento_slug" "text", "p_acompanhantes" "jsonb", "p_usa_transfer" boolean DEFAULT NULL::boolean, "p_transfer_origem" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_part   uuid;
  v_res    uuid;
  v_status jsonb;
  v_prazo  date;
  v_item   jsonb;
  v_nasc   date;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;

  v_status := part_meu_status(p_evento_slug);

  if not (v_status ->> 'rooming_liberado')::boolean then
    raise exception 'Rooming liberado apenas apos a assinatura do contrato'
      using errcode = '55000';
  end if;

  v_prazo := (v_status ->> 'prazo_rooming')::date;
  if v_prazo is not null and current_date > v_prazo and not is_staff() then
    raise exception 'Prazo de rooming encerrado em %', v_prazo
      using errcode = '55000';
  end if;

  -- valida antes de apagar qualquer coisa
  for v_item in select * from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb))
  loop
    if coalesce(trim(v_item ->> 'nome'),'') = '' then
      raise exception 'Todo acompanhante precisa de nome' using errcode = '22023';
    end if;
    v_nasc := nullif(v_item ->> 'data_nascimento','')::date;
    if v_nasc is not null and v_nasc > current_date then
      raise exception 'Data de nascimento no futuro: %', v_nasc
        using errcode = '22023';
    end if;
    -- crianca precisa de data de nascimento: e o que define a cobranca
    -- e a regra de cracha (menor de 21 fica sem)
    if coalesce(v_item ->> 'tipo','adulto') = 'crianca' and v_nasc is null then
      raise exception 'Informe a data de nascimento das criancas'
        using errcode = '22023';
    end if;
  end loop;

  v_res := _garantir_reserva(v_part);

  -- preserva o titular; troca so os acompanhantes
  delete from ocupantes where reserva_id = v_res and tipo <> 'titular';

  insert into ocupantes (reserva_id, nome, cpf, data_nascimento, tipo,
                         usa_transfer, categoria_cracha)
  select v_res,
         trim(x ->> 'nome'),
         nullif(x ->> 'cpf',''),
         nullif(x ->> 'data_nascimento','')::date,
         coalesce(nullif(x ->> 'tipo',''), 'adulto'),
         (x ->> 'usa_transfer')::boolean,
         'ACOMPANHANTE'
  from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb)) x;

  -- titular entra sozinho se ainda nao existe
  insert into ocupantes (reserva_id, nome, tipo, categoria_cracha, email)
  select v_res, g.nome, 'titular', 'PROTAGONISTA', g.email
  from participantes pa join gestores g on g.id = pa.gestor_id
  where pa.id = v_part
    and not exists (select 1 from ocupantes o
                    where o.reserva_id = v_res and o.tipo = 'titular');

  -- O transfer do titular vem no campo do formulario, nao na lista de
  -- acompanhantes. Sem gravar aqui, a fatura contaria um transfer a
  -- menos do que a previa mostrou na tela.
  update ocupantes set usa_transfer = coalesce(p_usa_transfer, usa_transfer)
   where reserva_id = v_res and tipo = 'titular';

  update reservas set
    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),
    transfer_origem = coalesce(p_transfer_origem, transfer_origem),
    status          = 'completo'
  where id = v_res;

  insert into notificacoes (evento_id, destinatario, tipo, assunto)
  select r.evento_id, g.email, 'rooming_ok', 'Dados de hospedagem confirmados'
  from reservas r
  join participantes pa on pa.id = r.participante_id
  join gestores g on g.id = pa.gestor_id
  where r.id = v_res;

  return part_calcular_fatura(p_evento_slug);
end;
$$;


ALTER FUNCTION "gestao"."part_salvar_rooming"("p_evento_slug" "text", "p_acompanhantes" "jsonb", "p_usa_transfer" boolean, "p_transfer_origem" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_cancelar_quarto_extra"("p_reserva_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_patro uuid; v_quarto uuid; v_origem text;
begin
  select patrocinador_id, quarto_id, origem
    into v_patro, v_quarto, v_origem
  from reservas where id = p_reserva_id;

  perform _exige_patrocinador(v_patro);

  if v_origem <> 'extra' then
    raise exception 'So quarto extra pode ser cancelado pelo portal'
      using errcode = '42501';
  end if;

  update reservas set status = 'cancelado' where id = p_reserva_id;
  update quartos  set status = 'disponivel' where id = v_quarto;

  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."patro_cancelar_quarto_extra"("p_reserva_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_comprar_quarto"("p_patrocinador_id" "uuid", "p_tipo" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento  uuid;
  v_quarto  uuid;
  v_reserva uuid;
  v_seq     int;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  if p_tipo not in ('single','duplo','triplo') then
    raise exception 'Tipo de quarto invalido: %', p_tipo using errcode = '22023';
  end if;

  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;

  select q.id into v_quarto
  from quartos q
  where q.evento_id = v_evento
    and q.tipo = p_tipo
    and q.status = 'disponivel'
    and not exists (select 1 from reservas r
                    where r.quarto_id = q.id and r.status <> 'cancelado')
  order by q.numero nulls last
  limit 1
  for update of q skip locked;

  if v_quarto is null then
    return jsonb_build_object('ok', false, 'motivo', 'sem_disponibilidade');
  end if;

  update quartos set status = 'reservado' where id = v_quarto;

  select count(*) + 1 into v_seq from reservas
   where patrocinador_id = p_patrocinador_id and status <> 'cancelado';

  insert into reservas (evento_id, quarto_id, patrocinador_id, rotulo,
                        tipo, origem, status)
  values (v_evento, v_quarto, p_patrocinador_id,
          'Quarto ' || v_seq, p_tipo, 'extra', 'rascunho')
  returning id into v_reserva;

  -- quarto novo em rascunho reabre a pendencia; o fechado_em ja gravado
  -- nao e apagado, para nao mexer na fila da mesa redonda
  return jsonb_build_object('ok', true, 'reserva_id', v_reserva, 'rotulo', 'Quarto ' || v_seq);
end;
$$;


ALTER FUNCTION "gestao"."patro_comprar_quarto"("p_patrocinador_id" "uuid", "p_tipo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_convidados_disponiveis"("p_sessao_id" "uuid") RETURNS TABLE("participante_id" "uuid", "nome" "text", "empresa" "text", "cargo" "text", "segmento" "text", "indicado_por_mim" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare s record;
begin
  select * into s from sessoes where id = p_sessao_id;
  if s.id is null then
    raise exception 'Sessao nao encontrada.' using errcode = 'P0002';
  end if;
  perform _exige_patrocinador(s.patrocinador_id);

  return query
  select
    pa.id, g.nome, g.empresa, g.cargo, g.segmento,
    coalesce(pa.indicado_por_patrocinador_id = s.patrocinador_id, false)
      as indicado_por_mim
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  left join participante_perfil pp on pp.participante_id = pa.id
  where pa.evento_id = s.evento_id
    and pa.status = 'aprovado'
    -- quem ja foi escolhido por qualquer empresa some da lista de todo
    -- mundo, dentro do mesmo tipo de sessao — e o que a tela promete
    and not exists (
      select 1 from sessao_convidados sc
      join sessoes s2 on s2.id = sc.sessao_id
      where sc.participante_id = pa.id
        and sc.status = 'confirmado'
        and s2.evento_id = s.evento_id
        and s2.tipo = s.tipo
    )
    -- e quem outra empresa indicou fica invisivel enquanto ela estiver
    -- no prazo. Vencido o prazo, a reserva cai e ele reaparece aqui.
    and coalesce(_reserva_da_indicacao(pa.id, s.tipo), s.patrocinador_id)
        = s.patrocinador_id
  order by
    -- o coalesce nao e decoracao: "null = uuid" da NULL, e em desc o
    -- Postgres ordena NULL, true, false — sem ele os NAO indicados
    -- subiriam acima dos indicados
    coalesce(pa.indicado_por_patrocinador_id = s.patrocinador_id, false) desc,
    _porte_faturamento(pp.faturamento) desc,
    g.nome;
end;
$$;


ALTER FUNCTION "gestao"."patro_convidados_disponiveis"("p_sessao_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_disponibilidade"("p_evento_slug" "text") RETURNS TABLE("tipo" "text", "livres" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  select v.tipo, v.livres
  from v_disponibilidade_quartos v
  join eventos e on e.id = v.evento_id
  where e.slug = p_evento_slug
  order by v.tipo;
$$;


ALTER FUNCTION "gestao"."patro_disponibilidade"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_escolher_convidados"("p_sessao_id" "uuid", "p_participantes" "uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_patro uuid; v_vagas int; v_tipo text; v_evento uuid;
  v_atual int; v_vez jsonb; v_inseridos int := 0; v_p uuid;
  v_dono uuid; v_empresa text;
begin
  select s.patrocinador_id, s.vagas, s.tipo, s.evento_id
    into v_patro, v_vagas, v_tipo, v_evento
  from sessoes s where s.id = p_sessao_id
  for update;                       -- trava a sessao durante a escolha

  perform _exige_patrocinador(v_patro);

  v_vez := patro_minha_vez(p_sessao_id);

  -- janela vencida vem antes da vez: com 0 na frente, a mensagem de
  -- "nao e a sua vez" nao explicaria nada
  if (v_vez ->> 'prazo_vencido')::boolean then
    raise exception 'O prazo da sua cota terminou em %. A escolha passou para as proximas cotas.',
      to_char((v_vez ->> 'janela_fim')::timestamptz, 'DD/MM/YYYY HH24:MI')
      using errcode = '55000';
  end if;

  if not (v_vez ->> 'minha_vez')::boolean then
    raise exception 'Ainda nao e a sua vez de escolher (% na frente)',
      v_vez ->> 'na_frente' using errcode = '55000';
  end if;

  select count(*) into v_atual from sessao_convidados
   where sessao_id = p_sessao_id and status = 'confirmado';

  if v_atual + array_length(p_participantes,1) > v_vagas then
    raise exception 'Cota de % vaga(s); voce ja tem % e tentou somar %',
      v_vagas, v_atual, array_length(p_participantes,1)
      using errcode = '22023';
  end if;

  foreach v_p in array p_participantes loop
    -- ninguem pode estar em duas sessoes do mesmo tipo
    if exists (
      select 1 from sessao_convidados sc
      join sessoes s3 on s3.id = sc.sessao_id
      where sc.participante_id = v_p and sc.status = 'confirmado'
        and s3.evento_id = v_evento and s3.tipo = v_tipo
    ) then
      raise exception 'Convidado ja esta em outra sessao deste tipo'
        using errcode = '23505';
    end if;

    v_dono := _reserva_da_indicacao(v_p, v_tipo);
    if v_dono is not null and v_dono <> v_patro then
      select empresa into v_empresa from patrocinadores where id = v_dono;
      raise exception 'Convidado indicado pela %, que ainda esta no prazo', v_empresa
        using errcode = '55000';
    end if;

    insert into sessao_convidados (sessao_id, participante_id, origem)
    values (p_sessao_id, v_p, 'patrocinador');
    v_inseridos := v_inseridos + 1;
  end loop;

  if v_atual + v_inseridos >= v_vagas then
    update sessoes set escolha_encerrada_em = now() where id = p_sessao_id;
  end if;

  return jsonb_build_object('ok', true, 'inseridos', v_inseridos,
                            'total', v_atual + v_inseridos, 'vagas', v_vagas);
end;
$$;


ALTER FUNCTION "gestao"."patro_escolher_convidados"("p_sessao_id" "uuid", "p_participantes" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_indicar_cio"("p_patrocinador_id" "uuid", "p_nome" "text", "p_empresa" "text" DEFAULT NULL::"text", "p_cargo" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text", "p_telefone" "text" DEFAULT NULL::"text", "p_observacao" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_evento uuid;
  v_dup    uuid;
  v_id     uuid;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Nome e obrigatorio' using errcode = '22023';
  end if;

  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;

  -- ja esta na base? marca como duplicado em vez de criar lixo
  select g.id into v_dup from gestores g
   where p_email is not null and g.email_norm = norm_doc(p_email);

  insert into indicacoes (evento_id, patrocinador_id, nome, empresa, cargo,
                          email, telefone, observacao, status, gestor_id)
  values (v_evento, p_patrocinador_id, trim(p_nome), p_empresa, p_cargo,
          p_email, p_telefone, p_observacao,
          case when v_dup is not null then 'duplicado' else 'nova' end,
          v_dup)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id,
                            'ja_na_base', v_dup is not null);
end;
$$;


ALTER FUNCTION "gestao"."patro_indicar_cio"("p_patrocinador_id" "uuid", "p_nome" "text", "p_empresa" "text", "p_cargo" "text", "p_email" "text", "p_telefone" "text", "p_observacao" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_listar_indicacoes"("p_patrocinador_id" "uuid") RETURNS TABLE("id" "uuid", "nome" "text", "empresa" "text", "status" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_patrocinador(p_patrocinador_id);
  return query
    select i.id, i.nome, i.empresa, i.status, i.created_at
    from indicacoes i
    where i.patrocinador_id = p_patrocinador_id
    order by i.created_at desc;
end;
$$;


ALTER FUNCTION "gestao"."patro_listar_indicacoes"("p_patrocinador_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_listar_ocupantes"("p_reserva_id" "uuid") RETURNS TABLE("ocupante_id" "uuid", "nome" "text", "cpf" "text", "data_nascimento" "date", "tipo" "text", "usa_transfer" boolean, "email" "text", "telefone" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_patro uuid;
begin
  select r.patrocinador_id into v_patro
  from reservas r where r.id = p_reserva_id;

  perform _exige_patrocinador(v_patro);

  return query
    select o.id, o.nome, o.cpf, o.data_nascimento,
           o.tipo, o.usa_transfer, o.email, o.telefone
    from ocupantes o where o.reserva_id = p_reserva_id
    order by o.created_at;
end;
$$;


ALTER FUNCTION "gestao"."patro_listar_ocupantes"("p_reserva_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_listar_quartos"("p_patrocinador_id" "uuid") RETURNS TABLE("reserva_id" "uuid", "rotulo" "text", "tipo" "text", "origem" "text", "capacidade" integer, "ocupantes" integer, "usa_transfer" boolean, "transfer_origem" "text", "status" "text", "quarto_numero" "text", "brinde_vai_enviar" boolean, "brinde_descricao" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_patrocinador(p_patrocinador_id);
  return query
    select
      r.id, r.rotulo, r.tipo, r.origem,
      case r.tipo when 'single' then 1 when 'duplo' then 2 else 3 end,
      (select count(*)::int from ocupantes o where o.reserva_id = r.id),
      r.usa_transfer, r.transfer_origem, r.status,
      q.numero,
      b.vai_enviar, b.descricao
    from reservas r
    left join quartos q on q.id = r.quarto_id
    left join brindes b on b.reserva_id = r.id
    where r.patrocinador_id = p_patrocinador_id
      and r.status <> 'cancelado'
    order by r.created_at;
end;
$$;


ALTER FUNCTION "gestao"."patro_listar_quartos"("p_patrocinador_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_manual"("p_evento_slug" "text") RETURNS TABLE("nome" "text", "local" "text", "data_inicio" "date", "data_fim" "date", "prazo_contrato" "date", "prazo_rooming" "date", "prazo_cancelamento" "date")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  select e.nome, e.local, e.data_inicio, e.data_fim,
         e.prazo_contrato, e.prazo_rooming, e.prazo_cancelamento
  from eventos e
  where e.slug = p_evento_slug and e.status <> 'rascunho';
$$;


ALTER FUNCTION "gestao"."patro_manual"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_meu_painel"("p_evento_slug" "text") RETURNS TABLE("patrocinador_id" "uuid", "empresa" "text", "cota" "text", "quartos_incluidos" integer, "tipo_quarto_padrao" "text", "vagas_mesa_redonda" integer, "tem_reuniao_exclusiva" boolean, "tem_jantar" boolean, "quartos_preenchidos" integer, "quartos_total" integer, "indicacoes_feitas" integer, "fechado" boolean, "quantas_empresas" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  select
    p.id, p.empresa, c.nome,
    coalesce((select sum(cq.quantidade)::int from cota_quartos cq
              where cq.cota_id = c.id), 0),
    c.tipo_quarto_padrao,
    coalesce(p.vagas_mesa_override, c.vagas_mesa_redonda),
    c.tem_reuniao_exclusiva,
    c.tem_jantar,
    (select count(*)::int from reservas r
      where r.patrocinador_id = p.id and r.status = 'completo'),
    (select count(*)::int from reservas r
      where r.patrocinador_id = p.id and r.status <> 'cancelado'),
    (select count(*)::int from indicacoes i where i.patrocinador_id = p.id),
    p.fechado_em is not null,
    count(*) over ()
  from patrocinadores p
  join eventos e on e.id = p.evento_id
  join cotas   c on c.id = p.cota_id
  where e.slug = p_evento_slug
    and p.status = 'ativo'
    and p.id in (select meus_patrocinadores())
  order by p.empresa;
$$;


ALTER FUNCTION "gestao"."patro_meu_painel"("p_evento_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_minha_vez"("p_sessao_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_patro uuid; v_evento uuid; v_tipo text; v_vagas int;
  v_pos bigint; v_na_frente int; v_escolhidos int;
  v_prazo date; v_inicio timestamptz; v_fim timestamptz;
begin
  select s.patrocinador_id, s.evento_id, s.tipo, s.vagas
    into v_patro, v_evento, v_tipo, v_vagas
  from sessoes s where s.id = p_sessao_id;

  perform _exige_patrocinador(v_patro);

  select o.posicao into v_pos
  from v_ordem_escolha o where o.patrocinador_id = v_patro;

  select c.prazo_indicacao into v_prazo
  from patrocinadores p join cotas c on c.id = p.cota_id
  where p.id = v_patro;

  select j.inicio, j.fim into v_inicio, v_fim
  from patrocinadores p
  join lateral _janelas_da_fila(v_evento, v_tipo) j on j.cota_id = p.cota_id
  where p.id = v_patro;

  select count(*) into v_na_frente
  from sessoes s2
  join v_ordem_escolha o2 on o2.patrocinador_id = s2.patrocinador_id
  where s2.evento_id = v_evento
    and s2.tipo = v_tipo
    and o2.posicao < coalesce(v_pos, 999999)
    and _escolha_em_aberto(s2.id);

  select count(*) into v_escolhidos from sessao_convidados
   where sessao_id = p_sessao_id and status = 'confirmado';

  return jsonb_build_object(
    -- nao basta nao ter ninguem na frente: a propria janela precisa
    -- estar de pe. Perder o prazo agora tira da escolha.
    'minha_vez',     v_na_frente = 0 and coalesce(_escolha_em_aberto(p_sessao_id), false),
    'posicao',       coalesce(v_pos, 0),
    'na_frente',     v_na_frente,
    'vagas',         v_vagas,
    'escolhidos',    v_escolhidos,
    'prazo',         v_prazo,
    'janela_inicio', v_inicio,
    'janela_fim',    v_fim,
    'prazo_vencido', v_fim is not null and now() >= v_fim
  );
end;
$$;


ALTER FUNCTION "gestao"."patro_minha_vez"("p_sessao_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_minhas_sessoes"("p_patrocinador_id" "uuid") RETURNS TABLE("sessao_id" "uuid", "tipo" "text", "data" "date", "horario" time without time zone, "local" "text", "vagas" integer, "escolhidos" bigint, "encerrada" boolean, "passou" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_patrocinador(p_patrocinador_id);
  return query
    select s.id, s.tipo, s.data, s.horario, s.local, s.vagas,
           (select count(*) from sessao_convidados sc
             where sc.sessao_id = s.id and sc.status = 'confirmado'),
           (s.escolha_encerrada_em is not null or s.passou_em is not null),
           (s.passou_em is not null)
    from sessoes s
    where s.patrocinador_id = p_patrocinador_id
    order by s.tipo, s.data, s.horario;
end;
$$;


ALTER FUNCTION "gestao"."patro_minhas_sessoes"("p_patrocinador_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_passar_a_vez"("p_sessao_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_patro uuid;
begin
  select patrocinador_id into v_patro from sessoes where id = p_sessao_id;
  perform _exige_patrocinador(v_patro);
  update sessoes set passou_em = now() where id = p_sessao_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "gestao"."patro_passar_a_vez"("p_sessao_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."patro_salvar_quarto"("p_reserva_id" "uuid", "p_ocupantes" "jsonb", "p_usa_transfer" boolean DEFAULT NULL::boolean, "p_transfer_origem" "text" DEFAULT NULL::"text", "p_brinde_enviar" boolean DEFAULT NULL::boolean, "p_brinde_descricao" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_patro uuid;
  v_tipo  text;
  v_cap   int;
  v_qtd   int;
  v_item  jsonb;
begin
  select patrocinador_id, tipo into v_patro, v_tipo
  from reservas where id = p_reserva_id and status <> 'cancelado';

  if v_patro is null then
    raise exception 'Reserva nao encontrada' using errcode = 'P0002';
  end if;
  perform _exige_patrocinador(v_patro);

  v_cap := case v_tipo when 'single' then 1 when 'duplo' then 2 else 3 end;
  v_qtd := jsonb_array_length(coalesce(p_ocupantes, '[]'::jsonb));

  if v_qtd > v_cap then
    raise exception 'Quarto % comporta % pessoa(s), recebidas %',
      v_tipo, v_cap, v_qtd using errcode = '22023';
  end if;

  -- nome vazio nao entra: e o erro mais comum no preenchimento
  for v_item in select * from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb))
  loop
    if coalesce(trim(v_item ->> 'nome'), '') = '' then
      raise exception 'Todo ocupante precisa de nome' using errcode = '22023';
    end if;
  end loop;

  delete from ocupantes where reserva_id = p_reserva_id;

  insert into ocupantes (reserva_id, nome, cpf, data_nascimento, tipo,
                         usa_transfer, email, telefone, categoria_cracha)
  select
    p_reserva_id,
    trim(x ->> 'nome'),
    nullif(x ->> 'cpf',''),
    nullif(x ->> 'data_nascimento','')::date,
    coalesce(nullif(x ->> 'tipo',''), 'adulto'),
    (x ->> 'usa_transfer')::boolean,
    nullif(x ->> 'email',''),
    nullif(x ->> 'telefone',''),
    'PATROCINADOR'
  from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb)) x;

  update reservas set
    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),
    transfer_origem = coalesce(p_transfer_origem, transfer_origem),
    -- preenchido = tem gente. Exigir a capacidade cheia prenderia em
    -- rascunho o duplo ocupado por uma pessoa so, que e caso legitimo,
    -- e travaria o fechado_em (logo, a fila da mesa redonda).
    status          = case when v_qtd > 0 then 'completo' else 'rascunho' end
  where id = p_reserva_id;

  if p_brinde_enviar is not null or p_brinde_descricao is not null then
    insert into brindes (patrocinador_id, reserva_id, vai_enviar, descricao)
    values (v_patro, p_reserva_id, coalesce(p_brinde_enviar,false), p_brinde_descricao)
    on conflict do nothing;

    update brindes set
      vai_enviar = coalesce(p_brinde_enviar, vai_enviar),
      descricao  = coalesce(p_brinde_descricao, descricao)
    where reserva_id = p_reserva_id;
  end if;

  perform _recalcular_fechado(v_patro);

  return jsonb_build_object('ok', true, 'ocupantes', v_qtd, 'capacidade', v_cap);
end;
$$;


ALTER FUNCTION "gestao"."patro_salvar_quarto"("p_reserva_id" "uuid", "p_ocupantes" "jsonb", "p_usa_transfer" boolean, "p_transfer_origem" "text", "p_brinde_enviar" boolean, "p_brinde_descricao" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."pode_ver_patrocinador"("p_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
  select is_staff() or p_id in (select meus_patrocinadores());
$$;


ALTER FUNCTION "gestao"."pode_ver_patrocinador"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao"."touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "gestao"."touch_updated_at"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "gestao"."admins" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text" NOT NULL,
    "email_norm" "text" GENERATED ALWAYS AS ("gestao"."norm_doc"("email")) STORED,
    "nome" "text",
    "role" "text" DEFAULT 'staff'::"text" NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "admins_role_check" CHECK (("role" = ANY (ARRAY['admin'::"text", 'staff'::"text"])))
);


ALTER TABLE "gestao"."admins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."auditoria" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tabela" "text" NOT NULL,
    "registro_id" "uuid",
    "acao" "text" NOT NULL,
    "campo" "text",
    "valor_antigo" "text",
    "valor_novo" "text",
    "usuario" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "gestao"."auditoria" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."brindes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patrocinador_id" "uuid" NOT NULL,
    "reserva_id" "uuid",
    "vai_enviar" boolean DEFAULT false NOT NULL,
    "descricao" "text",
    "quantidade" integer,
    "observacao" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "gestao"."brindes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."checkins" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evento_id" "uuid" NOT NULL,
    "patrocinador_id" "uuid",
    "ocupante_id" "uuid",
    "nome" "text" NOT NULL,
    "email" "text",
    "local" "text",
    "registrado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "registrado_por" "text",
    "desfeito_em" timestamp with time zone,
    "pessoa_key" "text",
    "desfeito_por" "text"
);


ALTER TABLE "gestao"."checkins" OWNER TO "postgres";


COMMENT ON COLUMN "gestao"."checkins"."desfeito_por" IS 'E-mail de quem desfez o check-in. Auditoria: o registro nao e apagado, so marcado.';



CREATE TABLE IF NOT EXISTS "gestao"."contratos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "participante_id" "uuid" NOT NULL,
    "autentique_id" "text",
    "autentique_url" "text",
    "status" "text" DEFAULT 'nao_enviado'::"text" NOT NULL,
    "enviado_em" timestamp with time zone,
    "assinado_em" timestamp with time zone,
    "lembretes_enviados" integer DEFAULT 0 NOT NULL,
    "ultimo_lembrete_em" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "contratos_status_check" CHECK (("status" = ANY (ARRAY['nao_enviado'::"text", 'enviado'::"text", 'assinado'::"text", 'recusado'::"text", 'cancelado'::"text"])))
);


ALTER TABLE "gestao"."contratos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."cota_quartos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cota_id" "uuid" NOT NULL,
    "tipo" "text" NOT NULL,
    "quantidade" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "cota_quartos_quantidade_check" CHECK (("quantidade" >= 0)),
    CONSTRAINT "cota_quartos_tipo_check" CHECK (("tipo" = ANY (ARRAY['single'::"text", 'duplo'::"text", 'triplo'::"text"])))
);


ALTER TABLE "gestao"."cota_quartos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."cotas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evento_id" "uuid" NOT NULL,
    "nome" "text" NOT NULL,
    "ordem_prioridade" integer NOT NULL,
    "quartos_incluidos" integer DEFAULT 0 NOT NULL,
    "tipo_quarto_padrao" "text" DEFAULT 'duplo'::"text" NOT NULL,
    "vagas_mesa_redonda" integer DEFAULT 0 NOT NULL,
    "tem_reuniao_exclusiva" boolean DEFAULT false NOT NULL,
    "tem_jantar" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "prazo_indicacao" "date",
    "janela_horas" integer,
    CONSTRAINT "cotas_janela_horas_check" CHECK ((("janela_horas" IS NULL) OR ("janela_horas" > 0))),
    CONSTRAINT "cotas_tipo_quarto_padrao_check" CHECK (("tipo_quarto_padrao" = ANY (ARRAY['single'::"text", 'duplo'::"text", 'triplo'::"text"])))
);


ALTER TABLE "gestao"."cotas" OWNER TO "postgres";


COMMENT ON COLUMN "gestao"."cotas"."prazo_indicacao" IS 'Ate quando esta cota escolhe. Vencido, a fila anda e as reservas de indicacao dela caem. Nulo = sem prazo.';



COMMENT ON COLUMN "gestao"."cotas"."janela_horas" IS 'Horas que esta cota tem para escolher, contadas do fim da cota anterior. Nulo = sem limite de tempo.';



CREATE TABLE IF NOT EXISTS "gestao"."eventos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "nome" "text" NOT NULL,
    "local" "text",
    "data_inicio" "date",
    "data_fim" "date",
    "status" "text" DEFAULT 'rascunho'::"text" NOT NULL,
    "prazo_contrato" "date",
    "prazo_rooming" "date",
    "prazo_cancelamento" "date",
    "sympla_event_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "cota_unica" boolean DEFAULT false NOT NULL,
    "escolha_abre_em" timestamp with time zone,
    CONSTRAINT "eventos_status_check" CHECK (("status" = ANY (ARRAY['rascunho'::"text", 'aberto'::"text", 'encerrado'::"text"])))
);


ALTER TABLE "gestao"."eventos" OWNER TO "postgres";


COMMENT ON COLUMN "gestao"."eventos"."escolha_abre_em" IS 'Quando a primeira cota comeca a contar a janela de escolha. Nulo = nada expira.';



CREATE TABLE IF NOT EXISTS "gestao"."fatura_itens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "fatura_id" "uuid" NOT NULL,
    "reserva_id" "uuid",
    "descricao" "text" NOT NULL,
    "quantidade" integer DEFAULT 1 NOT NULL,
    "valor_unit" numeric(12,2) DEFAULT 0 NOT NULL,
    "valor_total" numeric(12,2) GENERATED ALWAYS AS ((("quantidade")::numeric * "valor_unit")) STORED
);


ALTER TABLE "gestao"."fatura_itens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."faturas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evento_id" "uuid" NOT NULL,
    "participante_id" "uuid",
    "patrocinador_id" "uuid",
    "total" numeric(12,2) DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'estimada'::"text" NOT NULL,
    "emitida_em" timestamp with time zone,
    "paga_em" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "vencimento" "date",
    "observacao" "text",
    "forma_pagamento" "text",
    CONSTRAINT "faturas_status_check" CHECK (("status" = ANY (ARRAY['estimada'::"text", 'emitida'::"text", 'paga'::"text", 'cancelada'::"text"])))
);


ALTER TABLE "gestao"."faturas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."gestores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" "text" NOT NULL,
    "email" "text" NOT NULL,
    "email_norm" "text" GENERATED ALWAYS AS ("gestao"."norm_doc"("email")) STORED,
    "cpf" "text",
    "cpf_norm" "text" GENERATED ALWAYS AS ("gestao"."norm_cpf"("cpf")) STORED,
    "telefone" "text",
    "cargo" "text",
    "empresa" "text",
    "cnpj" "text",
    "segmento" "text",
    "estado" "text",
    "perfil" "text",
    "ativo" boolean DEFAULT true NOT NULL,
    "origem" "text" DEFAULT 'manual'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "posicao_gestor" "text",
    "cidade" "text",
    "faturamento" "text",
    "funcionarios" "text",
    CONSTRAINT "gestores_origem_check" CHECK (("origem" = ANY (ARRAY['manual'::"text", 'importacao'::"text", 'ia'::"text", 'autocadastro'::"text", 'indicacao'::"text"])))
);


ALTER TABLE "gestao"."gestores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."gestores_historico" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "gestor_id" "uuid" NOT NULL,
    "campo" "text" NOT NULL,
    "valor_antigo" "text",
    "valor_novo" "text",
    "detectado_por" "text" DEFAULT 'manual'::"text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "gestao"."gestores_historico" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."importacoes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evento_id" "uuid",
    "tipo" "text" NOT NULL,
    "arquivo" "text",
    "total_linhas" integer DEFAULT 0,
    "criados" integer DEFAULT 0,
    "atualizados" integer DEFAULT 0,
    "erros" integer DEFAULT 0,
    "executado_por" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "gestao"."importacoes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."indicacoes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evento_id" "uuid" NOT NULL,
    "patrocinador_id" "uuid" NOT NULL,
    "nome" "text" NOT NULL,
    "empresa" "text",
    "cargo" "text",
    "email" "text",
    "telefone" "text",
    "observacao" "text",
    "status" "text" DEFAULT 'nova'::"text" NOT NULL,
    "gestor_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "indicacoes_status_check" CHECK (("status" = ANY (ARRAY['nova'::"text", 'convidado'::"text", 'inscrito'::"text", 'recusado'::"text", 'duplicado'::"text"])))
);


ALTER TABLE "gestao"."indicacoes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."jantar_convidados" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "jantar_id" "uuid" NOT NULL,
    "gestor_id" "uuid" NOT NULL,
    "empresa" "text",
    "origem" "text" DEFAULT 'prospeccao'::"text" NOT NULL,
    "rotulo" "text",
    "score" numeric(5,2),
    "natureza" "text",
    "justificativa" "text",
    "status" "text" DEFAULT 'sugerido'::"text" NOT NULL,
    "observacao" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "jantar_convidados_origem_check" CHECK (("origem" = ANY (ARRAY['prospeccao'::"text", 'avulso'::"text", 'manual'::"text"]))),
    CONSTRAINT "jantar_convidados_status_check" CHECK (("status" = ANY (ARRAY['sugerido'::"text", 'convidado'::"text", 'confirmado'::"text", 'recusado'::"text", 'compareceu'::"text"])))
);


ALTER TABLE "gestao"."jantar_convidados" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."jantares" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "data" "date",
    "horario" time without time zone,
    "local" "text",
    "patrocinador_nome" "text" NOT NULL,
    "patrocinador_site" "text",
    "perfil_convidado" "text",
    "observacoes" "text",
    "abrangencia" "text",
    "capacidade" integer DEFAULT 8 NOT NULL,
    "status" "text" DEFAULT 'planejado'::"text" NOT NULL,
    "criado_por" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "jantares_status_check" CHECK (("status" = ANY (ARRAY['planejado'::"text", 'confirmado'::"text", 'realizado'::"text", 'cancelado'::"text"])))
);


ALTER TABLE "gestao"."jantares" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."notificacoes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evento_id" "uuid",
    "destinatario" "text" NOT NULL,
    "tipo" "text" NOT NULL,
    "assunto" "text",
    "status" "text" DEFAULT 'enfileirada'::"text" NOT NULL,
    "erro" "text",
    "enviada_em" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "notificacoes_status_check" CHECK (("status" = ANY (ARRAY['enfileirada'::"text", 'enviada'::"text", 'erro'::"text"])))
);


ALTER TABLE "gestao"."notificacoes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."ocupantes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "reserva_id" "uuid" NOT NULL,
    "nome" "text" NOT NULL,
    "cpf" "text",
    "data_nascimento" "date",
    "tipo" "text" DEFAULT 'adulto'::"text" NOT NULL,
    "categoria_cracha" "text",
    "usa_transfer" boolean,
    "email" "text",
    "telefone" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "ocupantes_tipo_check" CHECK (("tipo" = ANY (ARRAY['titular'::"text", 'adulto'::"text", 'crianca'::"text"])))
);


ALTER TABLE "gestao"."ocupantes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."participante_perfil" (
    "participante_id" "uuid" NOT NULL,
    "faturamento" "text",
    "orcamento_ti" "text",
    "colaboradores" "text",
    "colaboradores_ti" "text",
    "erp_atual" "text",
    "respostas" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "consentimento_lgpd" boolean,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "gestao"."participante_perfil" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."participantes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evento_id" "uuid" NOT NULL,
    "gestor_id" "uuid" NOT NULL,
    "sympla_id" "text",
    "tipo_ingresso" "text",
    "status" "text" DEFAULT 'pendente'::"text" NOT NULL,
    "origem" "text" DEFAULT 'sympla'::"text" NOT NULL,
    "indicado_por_patrocinador_id" "uuid",
    "aprovado_em" timestamp with time zone,
    "aprovado_por" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "participantes_origem_check" CHECK (("origem" = ANY (ARRAY['sympla'::"text", 'autocadastro'::"text", 'indicacao'::"text", 'manual'::"text"]))),
    CONSTRAINT "participantes_status_check" CHECK (("status" = ANY (ARRAY['pendente'::"text", 'aprovado'::"text", 'recusado'::"text", 'cancelado'::"text"])))
);


ALTER TABLE "gestao"."participantes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."patrocinadores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evento_id" "uuid" NOT NULL,
    "cota_id" "uuid",
    "empresa" "text" NOT NULL,
    "cnpj" "text",
    "segmento" "text",
    "o_que_vende" "text",
    "logo_url" "text",
    "quartos_extras_cota" integer DEFAULT 0 NOT NULL,
    "vagas_mesa_override" integer,
    "status" "text" DEFAULT 'ativo'::"text" NOT NULL,
    "fechado_em" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "site" "text",
    "resumo" "text",
    "cidade" "text",
    "estado" "text",
    "natureza" "text",
    "enriquecido_em" timestamp with time zone,
    CONSTRAINT "patrocinadores_natureza_check" CHECK ((("natureza" IS NULL) OR ("natureza" = ANY (ARRAY['privada'::"text", 'hibrida'::"text", 'publica'::"text"])))),
    CONSTRAINT "patrocinadores_status_check" CHECK (("status" = ANY (ARRAY['ativo'::"text", 'inativo'::"text"])))
);


ALTER TABLE "gestao"."patrocinadores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."precos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evento_id" "uuid" NOT NULL,
    "item" "text" NOT NULL,
    "descricao" "text",
    "valor" numeric(12,2) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "idade_min" integer,
    "idade_max" integer,
    CONSTRAINT "precos_faixa_ck" CHECK ((("idade_min" IS NULL) OR ("idade_max" IS NULL) OR ("idade_max" >= "idade_min")))
);


ALTER TABLE "gestao"."precos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."prospeccoes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evento_id" "uuid",
    "sessao_id" "uuid",
    "patrocinador_id" "uuid",
    "gestor_id" "uuid",
    "empresa" "text",
    "score" numeric(5,2),
    "natureza" "text",
    "justificativa" "text",
    "status" "text" DEFAULT 'sugerido'::"text" NOT NULL,
    "criado_por" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "prospeccoes_status_check" CHECK (("status" = ANY (ARRAY['sugerido'::"text", 'aprovado'::"text", 'descartado'::"text", 'convidado'::"text"])))
);


ALTER TABLE "gestao"."prospeccoes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."quartos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evento_id" "uuid" NOT NULL,
    "numero" "text",
    "tipo" "text" NOT NULL,
    "capacidade" integer NOT NULL,
    "bloco" "text",
    "status" "text" DEFAULT 'disponivel'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "quartos_status_check" CHECK (("status" = ANY (ARRAY['disponivel'::"text", 'reservado'::"text", 'bloqueado'::"text"]))),
    CONSTRAINT "quartos_tipo_check" CHECK (("tipo" = ANY (ARRAY['single'::"text", 'duplo'::"text", 'triplo'::"text"])))
);


ALTER TABLE "gestao"."quartos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."reservas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evento_id" "uuid" NOT NULL,
    "quarto_id" "uuid",
    "participante_id" "uuid",
    "patrocinador_id" "uuid",
    "rotulo" "text",
    "tipo" "text" NOT NULL,
    "origem" "text" DEFAULT 'cota'::"text" NOT NULL,
    "usa_transfer" boolean,
    "transfer_origem" "text",
    "status" "text" DEFAULT 'rascunho'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "reservas_dono_ck" CHECK (((("participante_id" IS NOT NULL) AND ("patrocinador_id" IS NULL)) OR (("participante_id" IS NULL) AND ("patrocinador_id" IS NOT NULL)))),
    CONSTRAINT "reservas_origem_check" CHECK (("origem" = ANY (ARRAY['cota'::"text", 'inscricao'::"text", 'extra'::"text"]))),
    CONSTRAINT "reservas_status_check" CHECK (("status" = ANY (ARRAY['rascunho'::"text", 'completo'::"text", 'cancelado'::"text"]))),
    CONSTRAINT "reservas_tipo_check" CHECK (("tipo" = ANY (ARRAY['single'::"text", 'duplo'::"text", 'triplo'::"text"])))
);


ALTER TABLE "gestao"."reservas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."sessao_convidados" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "sessao_id" "uuid" NOT NULL,
    "participante_id" "uuid" NOT NULL,
    "origem" "text" DEFAULT 'patrocinador'::"text" NOT NULL,
    "aderencia" numeric(5,2),
    "status" "text" DEFAULT 'confirmado'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "rotulo" "text",
    CONSTRAINT "sessao_convidados_origem_check" CHECK (("origem" = ANY (ARRAY['patrocinador'::"text", 'admin'::"text", 'match'::"text"]))),
    CONSTRAINT "sessao_convidados_status_check" CHECK (("status" = ANY (ARRAY['confirmado'::"text", 'removido'::"text"])))
);


ALTER TABLE "gestao"."sessao_convidados" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."sessoes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evento_id" "uuid" NOT NULL,
    "patrocinador_id" "uuid" NOT NULL,
    "tipo" "text" DEFAULT 'mesa_redonda'::"text" NOT NULL,
    "data" "date",
    "horario" time without time zone,
    "local" "text",
    "vagas" integer DEFAULT 0 NOT NULL,
    "escolha_liberada_em" timestamp with time zone,
    "escolha_encerrada_em" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "passou_em" timestamp with time zone,
    CONSTRAINT "sessoes_tipo_check" CHECK (("tipo" = ANY (ARRAY['mesa_redonda'::"text", 'reuniao_exclusiva'::"text", 'jantar'::"text"])))
);


ALTER TABLE "gestao"."sessoes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."sugestoes_ia" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tipo" "text" NOT NULL,
    "gestor_id" "uuid",
    "empresa" "text",
    "campo" "text",
    "valor_atual" "text",
    "valor_sugerido" "text",
    "confianca" numeric(5,2),
    "fonte" "text",
    "justificativa" "text",
    "status" "text" DEFAULT 'pendente'::"text" NOT NULL,
    "revisado_por" "text",
    "revisado_em" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "sugestoes_ia_status_check" CHECK (("status" = ANY (ARRAY['pendente'::"text", 'aprovada'::"text", 'ignorada'::"text", 'aplicada'::"text"]))),
    CONSTRAINT "sugestoes_ia_tipo_check" CHECK (("tipo" = ANY (ARRAY['troca_empresa'::"text", 'novo_gestor'::"text", 'nova_empresa'::"text", 'dado_divergente'::"text"])))
);


ALTER TABLE "gestao"."sugestoes_ia" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao"."usuarios_patrocinador" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patrocinador_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "email_norm" "text" GENERATED ALWAYS AS ("gestao"."norm_doc"("email")) STORED,
    "nome" "text",
    "telefone" "text",
    "ativo" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "gestao"."usuarios_patrocinador" OWNER TO "postgres";


CREATE OR REPLACE VIEW "gestao"."v_checkins_resumo" AS
 SELECT "c"."evento_id",
    "p"."empresa",
    "count"(*) AS "total_checkins"
   FROM ("gestao"."checkins" "c"
     JOIN "gestao"."patrocinadores" "p" ON (("p"."id" = "c"."patrocinador_id")))
  WHERE ("c"."desfeito_em" IS NULL)
  GROUP BY "c"."evento_id", "p"."empresa"
  ORDER BY "p"."empresa";


ALTER VIEW "gestao"."v_checkins_resumo" OWNER TO "postgres";


CREATE OR REPLACE VIEW "gestao"."v_disponibilidade_quartos" AS
 SELECT "evento_id",
    "tipo",
    "count"(*) FILTER (WHERE (("status" = 'disponivel'::"text") AND (NOT (EXISTS ( SELECT 1
           FROM "gestao"."reservas" "r"
          WHERE (("r"."quarto_id" = "q"."id") AND ("r"."status" <> 'cancelado'::"text"))))))) AS "livres",
    "count"(*) AS "total"
   FROM "gestao"."quartos" "q"
  GROUP BY "evento_id", "tipo";


ALTER VIEW "gestao"."v_disponibilidade_quartos" OWNER TO "postgres";


CREATE OR REPLACE VIEW "gestao"."v_esperados" AS
 SELECT "r"."evento_id",
    ('ocupante:'::"text" || ("o"."id")::"text") AS "pessoa_key",
    "o"."nome",
    COALESCE("p"."empresa", "g"."empresa") AS "empresa",
    COALESCE("o"."categoria_cracha",
        CASE
            WHEN ("r"."patrocinador_id" IS NOT NULL) THEN 'PATROCINADOR'::"text"
            WHEN ("o"."tipo" = 'titular'::"text") THEN 'PROTAGONISTA'::"text"
            ELSE 'ACOMPANHANTE'::"text"
        END) AS "categoria",
    "q"."numero" AS "quarto",
    "r"."patrocinador_id",
    COALESCE("o"."email", "g"."email") AS "email"
   FROM ((((("gestao"."ocupantes" "o"
     JOIN "gestao"."reservas" "r" ON ((("r"."id" = "o"."reserva_id") AND ("r"."status" <> 'cancelado'::"text"))))
     LEFT JOIN "gestao"."quartos" "q" ON (("q"."id" = "r"."quarto_id")))
     LEFT JOIN "gestao"."patrocinadores" "p" ON (("p"."id" = "r"."patrocinador_id")))
     LEFT JOIN "gestao"."participantes" "pa" ON (("pa"."id" = "r"."participante_id")))
     LEFT JOIN "gestao"."gestores" "g" ON (("g"."id" = "pa"."gestor_id")))
UNION ALL
 SELECT "pa"."evento_id",
    ('participante:'::"text" || ("pa"."id")::"text") AS "pessoa_key",
    "g"."nome",
    "g"."empresa",
    COALESCE(NULLIF("g"."perfil", ''::"text"), 'PROTAGONISTA'::"text") AS "categoria",
    NULL::"text" AS "quarto",
    NULL::"uuid" AS "patrocinador_id",
    "g"."email"
   FROM ("gestao"."participantes" "pa"
     JOIN "gestao"."gestores" "g" ON (("g"."id" = "pa"."gestor_id")))
  WHERE (("pa"."status" = 'aprovado'::"text") AND (NOT (EXISTS ( SELECT 1
           FROM "gestao"."reservas" "r"
          WHERE (("r"."participante_id" = "pa"."id") AND ("r"."status" <> 'cancelado'::"text"))))))
UNION ALL
 SELECT "p"."evento_id",
    ('usuario_patro:'::"text" || ("u"."id")::"text") AS "pessoa_key",
    COALESCE("u"."nome", "split_part"("u"."email", '@'::"text", 1)) AS "nome",
    "p"."empresa",
    'PATROCINADOR'::"text" AS "categoria",
    NULL::"text" AS "quarto",
    "p"."id" AS "patrocinador_id",
    "u"."email"
   FROM ("gestao"."usuarios_patrocinador" "u"
     JOIN "gestao"."patrocinadores" "p" ON (("p"."id" = "u"."patrocinador_id")))
  WHERE ("u"."ativo" AND ("p"."status" = 'ativo'::"text") AND (NOT (EXISTS ( SELECT 1
           FROM "gestao"."reservas" "r"
          WHERE (("r"."patrocinador_id" = "p"."id") AND ("r"."status" <> 'cancelado'::"text"))))));


ALTER VIEW "gestao"."v_esperados" OWNER TO "postgres";


CREATE OR REPLACE VIEW "gestao"."v_etiquetas" AS
 SELECT "r"."evento_id",
    "q"."numero" AS "apto",
    "o"."nome",
    COALESCE("p"."empresa", "g"."empresa") AS "empresa",
        CASE
            WHEN (("o"."data_nascimento" IS NOT NULL) AND ("age"(("o"."data_nascimento")::timestamp with time zone) < '21 years'::interval)) THEN 'S/CRACHA'::"text"
            ELSE COALESCE("o"."categoria_cracha",
            CASE
                WHEN ("r"."patrocinador_id" IS NOT NULL) THEN 'PATROCINADOR'::"text"
                WHEN ("o"."tipo" = 'titular'::"text") THEN 'PROTAGONISTA'::"text"
                ELSE 'ACOMPANHANTE'::"text"
            END)
        END AS "categoria",
    'quarto'::"text" AS "origem"
   FROM ((((("gestao"."ocupantes" "o"
     JOIN "gestao"."reservas" "r" ON ((("r"."id" = "o"."reserva_id") AND ("r"."status" <> 'cancelado'::"text"))))
     LEFT JOIN "gestao"."quartos" "q" ON (("q"."id" = "r"."quarto_id")))
     LEFT JOIN "gestao"."patrocinadores" "p" ON (("p"."id" = "r"."patrocinador_id")))
     LEFT JOIN "gestao"."participantes" "pa" ON (("pa"."id" = "r"."participante_id")))
     LEFT JOIN "gestao"."gestores" "g" ON (("g"."id" = "pa"."gestor_id")))
UNION ALL
 SELECT "pa"."evento_id",
    NULL::"text" AS "apto",
    "g"."nome",
    "g"."empresa",
    'PROTAGONISTA'::"text" AS "categoria",
    'inscricao'::"text" AS "origem"
   FROM ("gestao"."participantes" "pa"
     JOIN "gestao"."gestores" "g" ON (("g"."id" = "pa"."gestor_id")))
  WHERE (("pa"."status" = 'aprovado'::"text") AND (NOT (EXISTS ( SELECT 1
           FROM "gestao"."reservas" "r"
          WHERE (("r"."participante_id" = "pa"."id") AND ("r"."status" <> 'cancelado'::"text"))))))
UNION ALL
 SELECT "p"."evento_id",
    NULL::"text" AS "apto",
    COALESCE("u"."nome", "split_part"("u"."email", '@'::"text", 1)) AS "nome",
    "p"."empresa",
    'PATROCINADOR'::"text" AS "categoria",
    'patrocinador'::"text" AS "origem"
   FROM ("gestao"."usuarios_patrocinador" "u"
     JOIN "gestao"."patrocinadores" "p" ON (("p"."id" = "u"."patrocinador_id")))
  WHERE ("u"."ativo" AND ("p"."status" = 'ativo'::"text") AND (NOT (EXISTS ( SELECT 1
           FROM "gestao"."reservas" "r"
          WHERE (("r"."patrocinador_id" = "p"."id") AND ("r"."status" <> 'cancelado'::"text"))))));


ALTER VIEW "gestao"."v_etiquetas" OWNER TO "postgres";


CREATE OR REPLACE VIEW "gestao"."v_ordem_escolha" AS
 SELECT "p"."evento_id",
    "p"."id" AS "patrocinador_id",
    "p"."empresa",
    "c"."nome" AS "cota",
    "c"."ordem_prioridade",
    "p"."fechado_em",
    "row_number"() OVER (PARTITION BY "p"."evento_id" ORDER BY "c"."ordem_prioridade", "p"."fechado_em", "p"."created_at") AS "posicao"
   FROM ("gestao"."patrocinadores" "p"
     JOIN "gestao"."cotas" "c" ON (("c"."id" = "p"."cota_id")))
  WHERE ("p"."status" = 'ativo'::"text");


ALTER VIEW "gestao"."v_ordem_escolha" OWNER TO "postgres";


CREATE OR REPLACE VIEW "gestao"."v_painel_participantes" AS
 SELECT "pa"."evento_id",
    "pa"."id" AS "participante_id",
    "g"."nome",
    "g"."empresa",
    "g"."email",
    "pa"."status" AS "status_inscricao",
    COALESCE("ct"."status", 'nao_enviado'::"text") AS "status_contrato",
        CASE
            WHEN ("r"."id" IS NULL) THEN 'nao_iniciado'::"text"
            WHEN ("r"."status" = 'completo'::"text") THEN 'completo'::"text"
            ELSE 'parcial'::"text"
        END AS "status_rooming",
    "r"."usa_transfer",
    "q"."numero" AS "quarto"
   FROM (((("gestao"."participantes" "pa"
     JOIN "gestao"."gestores" "g" ON (("g"."id" = "pa"."gestor_id")))
     LEFT JOIN "gestao"."contratos" "ct" ON (("ct"."participante_id" = "pa"."id")))
     LEFT JOIN "gestao"."reservas" "r" ON ((("r"."participante_id" = "pa"."id") AND ("r"."status" <> 'cancelado'::"text"))))
     LEFT JOIN "gestao"."quartos" "q" ON (("q"."id" = "r"."quarto_id")));


ALTER VIEW "gestao"."v_painel_participantes" OWNER TO "postgres";


ALTER TABLE ONLY "gestao"."admins"
    ADD CONSTRAINT "admins_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."auditoria"
    ADD CONSTRAINT "auditoria_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."brindes"
    ADD CONSTRAINT "brindes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."checkins"
    ADD CONSTRAINT "checkins_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."contratos"
    ADD CONSTRAINT "contratos_participante_id_key" UNIQUE ("participante_id");



ALTER TABLE ONLY "gestao"."contratos"
    ADD CONSTRAINT "contratos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."cota_quartos"
    ADD CONSTRAINT "cota_quartos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."cotas"
    ADD CONSTRAINT "cotas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."eventos"
    ADD CONSTRAINT "eventos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."eventos"
    ADD CONSTRAINT "eventos_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "gestao"."fatura_itens"
    ADD CONSTRAINT "fatura_itens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."faturas"
    ADD CONSTRAINT "faturas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."gestores_historico"
    ADD CONSTRAINT "gestores_historico_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."gestores"
    ADD CONSTRAINT "gestores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."importacoes"
    ADD CONSTRAINT "importacoes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."indicacoes"
    ADD CONSTRAINT "indicacoes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."jantar_convidados"
    ADD CONSTRAINT "jantar_convidados_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."jantares"
    ADD CONSTRAINT "jantares_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."notificacoes"
    ADD CONSTRAINT "notificacoes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."ocupantes"
    ADD CONSTRAINT "ocupantes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."participante_perfil"
    ADD CONSTRAINT "participante_perfil_pkey" PRIMARY KEY ("participante_id");



ALTER TABLE ONLY "gestao"."participantes"
    ADD CONSTRAINT "participantes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."patrocinadores"
    ADD CONSTRAINT "patrocinadores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."precos"
    ADD CONSTRAINT "precos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."prospeccoes"
    ADD CONSTRAINT "prospeccoes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."quartos"
    ADD CONSTRAINT "quartos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."reservas"
    ADD CONSTRAINT "reservas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."sessao_convidados"
    ADD CONSTRAINT "sessao_convidados_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."sessoes"
    ADD CONSTRAINT "sessoes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."sugestoes_ia"
    ADD CONSTRAINT "sugestoes_ia_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao"."usuarios_patrocinador"
    ADD CONSTRAINT "usuarios_patrocinador_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "admins_email_uk" ON "gestao"."admins" USING "btree" ("email_norm");



CREATE INDEX "auditoria_ix" ON "gestao"."auditoria" USING "btree" ("tabela", "registro_id", "created_at" DESC);



CREATE UNIQUE INDEX "brindes_reserva_uk" ON "gestao"."brindes" USING "btree" ("reserva_id") WHERE ("reserva_id" IS NOT NULL);



CREATE INDEX "checkins_data_ix" ON "gestao"."checkins" USING "btree" ("evento_id", "registrado_em");



CREATE INDEX "checkins_ocupante_ix" ON "gestao"."checkins" USING "btree" ("ocupante_id") WHERE ("desfeito_em" IS NULL);



CREATE INDEX "checkins_patro_ix" ON "gestao"."checkins" USING "btree" ("evento_id", "patrocinador_id");



CREATE INDEX "checkins_pessoa_ix" ON "gestao"."checkins" USING "btree" ("evento_id", "pessoa_key") WHERE ("desfeito_em" IS NULL);



CREATE INDEX "contratos_status_ix" ON "gestao"."contratos" USING "btree" ("status");



CREATE UNIQUE INDEX "cota_quartos_uk" ON "gestao"."cota_quartos" USING "btree" ("cota_id", "tipo");



CREATE UNIQUE INDEX "cotas_uk" ON "gestao"."cotas" USING "btree" ("evento_id", "nome");



CREATE INDEX "fatura_itens_ix" ON "gestao"."fatura_itens" USING "btree" ("fatura_id");



CREATE UNIQUE INDEX "gestores_email_uk" ON "gestao"."gestores" USING "btree" ("email_norm");



CREATE INDEX "gestores_empresa_ix" ON "gestao"."gestores" USING "btree" ("lower"("empresa"));



CREATE INDEX "gestores_hist_ix" ON "gestao"."gestores_historico" USING "btree" ("gestor_id", "created_at" DESC);



CREATE INDEX "indicacoes_patro_ix" ON "gestao"."indicacoes" USING "btree" ("patrocinador_id");



CREATE INDEX "jantar_convidados_gestor_ix" ON "gestao"."jantar_convidados" USING "btree" ("gestor_id");



CREATE UNIQUE INDEX "jantar_convidados_uk" ON "gestao"."jantar_convidados" USING "btree" ("jantar_id", "gestor_id");



CREATE INDEX "jantares_data_ix" ON "gestao"."jantares" USING "btree" ("data");



CREATE INDEX "notificacoes_ix" ON "gestao"."notificacoes" USING "btree" ("status", "tipo");



CREATE INDEX "ocupantes_reserva_ix" ON "gestao"."ocupantes" USING "btree" ("reserva_id");



CREATE INDEX "participantes_status_ix" ON "gestao"."participantes" USING "btree" ("evento_id", "status");



CREATE UNIQUE INDEX "participantes_uk" ON "gestao"."participantes" USING "btree" ("evento_id", "gestor_id");



CREATE UNIQUE INDEX "patrocinadores_uk" ON "gestao"."patrocinadores" USING "btree" ("evento_id", "lower"("empresa"));



CREATE UNIQUE INDEX "precos_faixa_uk" ON "gestao"."precos" USING "btree" ("evento_id", "item", COALESCE("idade_min", '-1'::integer), COALESCE("idade_max", 999));



CREATE INDEX "prospeccoes_ix" ON "gestao"."prospeccoes" USING "btree" ("evento_id", "sessao_id", "status");



CREATE INDEX "quartos_disp_ix" ON "gestao"."quartos" USING "btree" ("evento_id", "tipo", "status");



CREATE UNIQUE INDEX "quartos_uk" ON "gestao"."quartos" USING "btree" ("evento_id", "numero") WHERE ("numero" IS NOT NULL);



CREATE INDEX "reservas_part_ix" ON "gestao"."reservas" USING "btree" ("participante_id");



CREATE INDEX "reservas_patro_ix" ON "gestao"."reservas" USING "btree" ("patrocinador_id");



CREATE INDEX "reservas_quarto_ix" ON "gestao"."reservas" USING "btree" ("quarto_id");



CREATE UNIQUE INDEX "sessao_conv_uk" ON "gestao"."sessao_convidados" USING "btree" ("sessao_id", "participante_id") WHERE ("status" = 'confirmado'::"text");



CREATE INDEX "sessoes_evento_ix" ON "gestao"."sessoes" USING "btree" ("evento_id", "tipo");



CREATE INDEX "sugestoes_status_ix" ON "gestao"."sugestoes_ia" USING "btree" ("status", "tipo");



CREATE INDEX "usuarios_patro_email_ix" ON "gestao"."usuarios_patrocinador" USING "btree" ("email_norm");



CREATE UNIQUE INDEX "usuarios_patro_uk" ON "gestao"."usuarios_patrocinador" USING "btree" ("patrocinador_id", "email_norm");



CREATE OR REPLACE TRIGGER "trg_brindes_upd" BEFORE UPDATE ON "gestao"."brindes" FOR EACH ROW EXECUTE FUNCTION "gestao"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_contratos_upd" BEFORE UPDATE ON "gestao"."contratos" FOR EACH ROW EXECUTE FUNCTION "gestao"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_eventos_upd" BEFORE UPDATE ON "gestao"."eventos" FOR EACH ROW EXECUTE FUNCTION "gestao"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_faturas_upd" BEFORE UPDATE ON "gestao"."faturas" FOR EACH ROW EXECUTE FUNCTION "gestao"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_gestores_upd" BEFORE UPDATE ON "gestao"."gestores" FOR EACH ROW EXECUTE FUNCTION "gestao"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_indicacoes_upd" BEFORE UPDATE ON "gestao"."indicacoes" FOR EACH ROW EXECUTE FUNCTION "gestao"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_jantar_conv_upd" BEFORE UPDATE ON "gestao"."jantar_convidados" FOR EACH ROW EXECUTE FUNCTION "gestao"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_jantares_upd" BEFORE UPDATE ON "gestao"."jantares" FOR EACH ROW EXECUTE FUNCTION "gestao"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_ocupantes_upd" BEFORE UPDATE ON "gestao"."ocupantes" FOR EACH ROW EXECUTE FUNCTION "gestao"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_participantes_upd" BEFORE UPDATE ON "gestao"."participantes" FOR EACH ROW EXECUTE FUNCTION "gestao"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_patrocinadores_upd" BEFORE UPDATE ON "gestao"."patrocinadores" FOR EACH ROW EXECUTE FUNCTION "gestao"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_reservas_upd" BEFORE UPDATE ON "gestao"."reservas" FOR EACH ROW EXECUTE FUNCTION "gestao"."touch_updated_at"();



ALTER TABLE ONLY "gestao"."brindes"
    ADD CONSTRAINT "brindes_patrocinador_id_fkey" FOREIGN KEY ("patrocinador_id") REFERENCES "gestao"."patrocinadores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."brindes"
    ADD CONSTRAINT "brindes_reserva_id_fkey" FOREIGN KEY ("reserva_id") REFERENCES "gestao"."reservas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."checkins"
    ADD CONSTRAINT "checkins_evento_id_fkey" FOREIGN KEY ("evento_id") REFERENCES "gestao"."eventos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."checkins"
    ADD CONSTRAINT "checkins_ocupante_id_fkey" FOREIGN KEY ("ocupante_id") REFERENCES "gestao"."ocupantes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao"."checkins"
    ADD CONSTRAINT "checkins_patrocinador_id_fkey" FOREIGN KEY ("patrocinador_id") REFERENCES "gestao"."patrocinadores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao"."contratos"
    ADD CONSTRAINT "contratos_participante_id_fkey" FOREIGN KEY ("participante_id") REFERENCES "gestao"."participantes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."cota_quartos"
    ADD CONSTRAINT "cota_quartos_cota_id_fkey" FOREIGN KEY ("cota_id") REFERENCES "gestao"."cotas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."cotas"
    ADD CONSTRAINT "cotas_evento_id_fkey" FOREIGN KEY ("evento_id") REFERENCES "gestao"."eventos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."fatura_itens"
    ADD CONSTRAINT "fatura_itens_fatura_id_fkey" FOREIGN KEY ("fatura_id") REFERENCES "gestao"."faturas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."fatura_itens"
    ADD CONSTRAINT "fatura_itens_reserva_id_fkey" FOREIGN KEY ("reserva_id") REFERENCES "gestao"."reservas"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao"."faturas"
    ADD CONSTRAINT "faturas_evento_id_fkey" FOREIGN KEY ("evento_id") REFERENCES "gestao"."eventos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."faturas"
    ADD CONSTRAINT "faturas_participante_id_fkey" FOREIGN KEY ("participante_id") REFERENCES "gestao"."participantes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."faturas"
    ADD CONSTRAINT "faturas_patrocinador_id_fkey" FOREIGN KEY ("patrocinador_id") REFERENCES "gestao"."patrocinadores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."gestores_historico"
    ADD CONSTRAINT "gestores_historico_gestor_id_fkey" FOREIGN KEY ("gestor_id") REFERENCES "gestao"."gestores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."importacoes"
    ADD CONSTRAINT "importacoes_evento_id_fkey" FOREIGN KEY ("evento_id") REFERENCES "gestao"."eventos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao"."indicacoes"
    ADD CONSTRAINT "indicacoes_evento_id_fkey" FOREIGN KEY ("evento_id") REFERENCES "gestao"."eventos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."indicacoes"
    ADD CONSTRAINT "indicacoes_gestor_id_fkey" FOREIGN KEY ("gestor_id") REFERENCES "gestao"."gestores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao"."indicacoes"
    ADD CONSTRAINT "indicacoes_patrocinador_id_fkey" FOREIGN KEY ("patrocinador_id") REFERENCES "gestao"."patrocinadores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."jantar_convidados"
    ADD CONSTRAINT "jantar_convidados_gestor_id_fkey" FOREIGN KEY ("gestor_id") REFERENCES "gestao"."gestores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."jantar_convidados"
    ADD CONSTRAINT "jantar_convidados_jantar_id_fkey" FOREIGN KEY ("jantar_id") REFERENCES "gestao"."jantares"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."notificacoes"
    ADD CONSTRAINT "notificacoes_evento_id_fkey" FOREIGN KEY ("evento_id") REFERENCES "gestao"."eventos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."ocupantes"
    ADD CONSTRAINT "ocupantes_reserva_id_fkey" FOREIGN KEY ("reserva_id") REFERENCES "gestao"."reservas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."participante_perfil"
    ADD CONSTRAINT "participante_perfil_participante_id_fkey" FOREIGN KEY ("participante_id") REFERENCES "gestao"."participantes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."participantes"
    ADD CONSTRAINT "participantes_evento_id_fkey" FOREIGN KEY ("evento_id") REFERENCES "gestao"."eventos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."participantes"
    ADD CONSTRAINT "participantes_gestor_id_fkey" FOREIGN KEY ("gestor_id") REFERENCES "gestao"."gestores"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "gestao"."participantes"
    ADD CONSTRAINT "participantes_indicador_fk" FOREIGN KEY ("indicado_por_patrocinador_id") REFERENCES "gestao"."patrocinadores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao"."patrocinadores"
    ADD CONSTRAINT "patrocinadores_cota_id_fkey" FOREIGN KEY ("cota_id") REFERENCES "gestao"."cotas"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao"."patrocinadores"
    ADD CONSTRAINT "patrocinadores_evento_id_fkey" FOREIGN KEY ("evento_id") REFERENCES "gestao"."eventos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."precos"
    ADD CONSTRAINT "precos_evento_id_fkey" FOREIGN KEY ("evento_id") REFERENCES "gestao"."eventos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."prospeccoes"
    ADD CONSTRAINT "prospeccoes_evento_id_fkey" FOREIGN KEY ("evento_id") REFERENCES "gestao"."eventos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."prospeccoes"
    ADD CONSTRAINT "prospeccoes_gestor_id_fkey" FOREIGN KEY ("gestor_id") REFERENCES "gestao"."gestores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."prospeccoes"
    ADD CONSTRAINT "prospeccoes_patrocinador_id_fkey" FOREIGN KEY ("patrocinador_id") REFERENCES "gestao"."patrocinadores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao"."prospeccoes"
    ADD CONSTRAINT "prospeccoes_sessao_id_fkey" FOREIGN KEY ("sessao_id") REFERENCES "gestao"."sessoes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao"."quartos"
    ADD CONSTRAINT "quartos_evento_id_fkey" FOREIGN KEY ("evento_id") REFERENCES "gestao"."eventos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."reservas"
    ADD CONSTRAINT "reservas_evento_id_fkey" FOREIGN KEY ("evento_id") REFERENCES "gestao"."eventos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."reservas"
    ADD CONSTRAINT "reservas_participante_id_fkey" FOREIGN KEY ("participante_id") REFERENCES "gestao"."participantes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."reservas"
    ADD CONSTRAINT "reservas_patrocinador_id_fkey" FOREIGN KEY ("patrocinador_id") REFERENCES "gestao"."patrocinadores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."reservas"
    ADD CONSTRAINT "reservas_quarto_id_fkey" FOREIGN KEY ("quarto_id") REFERENCES "gestao"."quartos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao"."sessao_convidados"
    ADD CONSTRAINT "sessao_convidados_participante_id_fkey" FOREIGN KEY ("participante_id") REFERENCES "gestao"."participantes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."sessao_convidados"
    ADD CONSTRAINT "sessao_convidados_sessao_id_fkey" FOREIGN KEY ("sessao_id") REFERENCES "gestao"."sessoes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."sessoes"
    ADD CONSTRAINT "sessoes_evento_id_fkey" FOREIGN KEY ("evento_id") REFERENCES "gestao"."eventos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."sessoes"
    ADD CONSTRAINT "sessoes_patrocinador_id_fkey" FOREIGN KEY ("patrocinador_id") REFERENCES "gestao"."patrocinadores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."sugestoes_ia"
    ADD CONSTRAINT "sugestoes_ia_gestor_id_fkey" FOREIGN KEY ("gestor_id") REFERENCES "gestao"."gestores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao"."usuarios_patrocinador"
    ADD CONSTRAINT "usuarios_patrocinador_patrocinador_id_fkey" FOREIGN KEY ("patrocinador_id") REFERENCES "gestao"."patrocinadores"("id") ON DELETE CASCADE;



ALTER TABLE "gestao"."admins" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "admins_staff_all" ON "gestao"."admins" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."auditoria" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "auditoria_staff_all" ON "gestao"."auditoria" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."brindes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "brindes_staff_all" ON "gestao"."brindes" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."checkins" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "checkins_staff_all" ON "gestao"."checkins" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."contratos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "contratos_staff_all" ON "gestao"."contratos" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."cota_quartos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cota_quartos_staff_all" ON "gestao"."cota_quartos" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."cotas" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cotas_staff_all" ON "gestao"."cotas" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."eventos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "eventos_read_pub" ON "gestao"."eventos" FOR SELECT USING ((("status" <> 'rascunho'::"text") OR "gestao"."is_staff"()));



CREATE POLICY "eventos_staff_all" ON "gestao"."eventos" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."fatura_itens" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "fatura_itens_staff_all" ON "gestao"."fatura_itens" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."faturas" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "faturas_staff_all" ON "gestao"."faturas" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."gestores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao"."gestores_historico" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "gestores_historico_staff_all" ON "gestao"."gestores_historico" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



CREATE POLICY "gestores_staff_all" ON "gestao"."gestores" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."importacoes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "importacoes_staff_all" ON "gestao"."importacoes" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."indicacoes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "indicacoes_staff_all" ON "gestao"."indicacoes" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."jantar_convidados" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "jantar_convidados_staff_all" ON "gestao"."jantar_convidados" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."jantares" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "jantares_staff_all" ON "gestao"."jantares" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."notificacoes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notificacoes_staff_all" ON "gestao"."notificacoes" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."ocupantes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ocupantes_staff_all" ON "gestao"."ocupantes" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."participante_perfil" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "participante_perfil_staff_all" ON "gestao"."participante_perfil" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."participantes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "participantes_staff_all" ON "gestao"."participantes" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



CREATE POLICY "patro_brindes_read" ON "gestao"."brindes" FOR SELECT USING (("patrocinador_id" IN ( SELECT "gestao"."meus_patrocinadores"() AS "meus_patrocinadores")));



CREATE POLICY "patro_indicacoes_read" ON "gestao"."indicacoes" FOR SELECT USING (("patrocinador_id" IN ( SELECT "gestao"."meus_patrocinadores"() AS "meus_patrocinadores")));



CREATE POLICY "patro_ocupantes_read" ON "gestao"."ocupantes" FOR SELECT USING (("reserva_id" IN ( SELECT "reservas"."id"
   FROM "gestao"."reservas"
  WHERE ("reservas"."patrocinador_id" IN ( SELECT "gestao"."meus_patrocinadores"() AS "meus_patrocinadores")))));



CREATE POLICY "patro_reservas_read" ON "gestao"."reservas" FOR SELECT USING (("patrocinador_id" IN ( SELECT "gestao"."meus_patrocinadores"() AS "meus_patrocinadores")));



CREATE POLICY "patro_self_read" ON "gestao"."patrocinadores" FOR SELECT USING (("id" IN ( SELECT "gestao"."meus_patrocinadores"() AS "meus_patrocinadores")));



CREATE POLICY "patro_sessoes_read" ON "gestao"."sessoes" FOR SELECT USING (("patrocinador_id" IN ( SELECT "gestao"."meus_patrocinadores"() AS "meus_patrocinadores")));



CREATE POLICY "patro_usuarios_read" ON "gestao"."usuarios_patrocinador" FOR SELECT USING (("patrocinador_id" IN ( SELECT "gestao"."meus_patrocinadores"() AS "meus_patrocinadores")));



ALTER TABLE "gestao"."patrocinadores" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "patrocinadores_staff_all" ON "gestao"."patrocinadores" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."precos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "precos_staff_all" ON "gestao"."precos" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."prospeccoes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "prospeccoes_staff_all" ON "gestao"."prospeccoes" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."quartos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "quartos_staff_all" ON "gestao"."quartos" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."reservas" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "reservas_staff_all" ON "gestao"."reservas" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."sessao_convidados" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sessao_convidados_staff_all" ON "gestao"."sessao_convidados" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."sessoes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sessoes_staff_all" ON "gestao"."sessoes" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."sugestoes_ia" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sugestoes_ia_staff_all" ON "gestao"."sugestoes_ia" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



ALTER TABLE "gestao"."usuarios_patrocinador" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usuarios_patrocinador_staff_all" ON "gestao"."usuarios_patrocinador" USING ("gestao"."is_staff"()) WITH CHECK ("gestao"."is_staff"());



GRANT USAGE ON SCHEMA "gestao" TO "anon";
GRANT USAGE ON SCHEMA "gestao" TO "authenticated";
GRANT USAGE ON SCHEMA "gestao" TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_escolha_em_aberto"("p_sessao_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_escolha_em_aberto"("p_sessao_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_escolha_em_aberto"("p_sessao_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_exige_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_exige_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_exige_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_exige_participante"("p_participante_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_exige_participante"("p_participante_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_exige_participante"("p_participante_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_exige_patrocinador"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_exige_patrocinador"("p_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."_exige_patrocinador"("p_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."_exige_staff"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_exige_staff"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_exige_staff"() TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_fim_da_janela"("p_inicio" timestamp with time zone, "p_horas" integer, "p_prazo" "date", "p_fechou" timestamp with time zone, "p_sem_sessao" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_fim_da_janela"("p_inicio" timestamp with time zone, "p_horas" integer, "p_prazo" "date", "p_fechou" timestamp with time zone, "p_sem_sessao" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_fim_da_janela"("p_inicio" timestamp with time zone, "p_horas" integer, "p_prazo" "date", "p_fechou" timestamp with time zone, "p_sem_sessao" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_garantir_reserva"("p_participante_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_garantir_reserva"("p_participante_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_garantir_reserva"("p_participante_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_idade_no_evento"("p_evento" "uuid", "p_nascimento" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_idade_no_evento"("p_evento" "uuid", "p_nascimento" "date") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_idade_no_evento"("p_evento" "uuid", "p_nascimento" "date") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_intencao"("v" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_intencao"("v" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_intencao"("v" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_item_do_ocupante"("p_tipo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_item_do_ocupante"("p_tipo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_item_do_ocupante"("p_tipo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_janelas_da_fila"("p_evento" "uuid", "p_tipo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_janelas_da_fila"("p_evento" "uuid", "p_tipo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_janelas_da_fila"("p_evento" "uuid", "p_tipo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_meu_participante"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_meu_participante"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_meu_participante"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_porte_faturamento"("p_texto" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_porte_faturamento"("p_texto" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_porte_faturamento"("p_texto" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_preco_item"("p_evento" "uuid", "p_item" "text", "p_idade" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_preco_item"("p_evento" "uuid", "p_item" "text", "p_idade" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_preco_item"("p_evento" "uuid", "p_item" "text", "p_idade" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_rank_cargo"("v" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_rank_cargo"("v" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_rank_cargo"("v" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_rank_pos"("v" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_rank_pos"("v" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_rank_pos"("v" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_recalcular_fatura_participante"("p_participante_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_recalcular_fatura_participante"("p_participante_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_recalcular_fatura_participante"("p_participante_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_recalcular_fatura_patrocinador"("p_patrocinador_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_recalcular_fatura_patrocinador"("p_patrocinador_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_recalcular_fatura_patrocinador"("p_patrocinador_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_recalcular_fechado"("p_patrocinador_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_recalcular_fechado"("p_patrocinador_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."_recalcular_fechado"("p_patrocinador_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."_reserva_da_indicacao"("p_participante_id" "uuid", "p_tipo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_reserva_da_indicacao"("p_participante_id" "uuid", "p_tipo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_reserva_da_indicacao"("p_participante_id" "uuid", "p_tipo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."_rotulo_faixa"("p_min" integer, "p_max" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."_rotulo_faixa"("p_min" integer, "p_max" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."_rotulo_faixa"("p_min" integer, "p_max" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_adicionar_convidado_sessao"("p_sessao_id" "uuid", "p_participante_id" "uuid", "p_aderencia" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_adicionar_convidado_sessao"("p_sessao_id" "uuid", "p_participante_id" "uuid", "p_aderencia" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_adicionar_convidado_sessao"("p_sessao_id" "uuid", "p_participante_id" "uuid", "p_aderencia" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_alocar_quarto"("p_reserva_id" "uuid", "p_quarto_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_alocar_quarto"("p_reserva_id" "uuid", "p_quarto_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_alocar_quarto"("p_reserva_id" "uuid", "p_quarto_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_aplicar_sugestao"("p_sugestao_id" "uuid", "p_aprovar" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_aplicar_sugestao"("p_sugestao_id" "uuid", "p_aprovar" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_aplicar_sugestao"("p_sugestao_id" "uuid", "p_aprovar" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_aprovar_participante"("p_participante_id" "uuid", "p_aprovado" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_aprovar_participante"("p_participante_id" "uuid", "p_aprovado" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_aprovar_participante"("p_participante_id" "uuid", "p_aprovado" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_converter_indicacao"("p_indicacao_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_converter_indicacao"("p_indicacao_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_converter_indicacao"("p_indicacao_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_convidado_avulso"("p_sessao_id" "uuid", "p_nome" "text", "p_empresa" "text", "p_email" "text", "p_telefone" "text", "p_cargo" "text", "p_rotulo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_convidado_avulso"("p_sessao_id" "uuid", "p_nome" "text", "p_empresa" "text", "p_email" "text", "p_telefone" "text", "p_cargo" "text", "p_rotulo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_convidado_avulso"("p_sessao_id" "uuid", "p_nome" "text", "p_empresa" "text", "p_email" "text", "p_telefone" "text", "p_cargo" "text", "p_rotulo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_convidados_sessao"("p_sessao_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_convidados_sessao"("p_sessao_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_convidados_sessao"("p_sessao_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_criar_faixa_quartos"("p_evento_slug" "text", "p_de" integer, "p_ate" integer, "p_tipo" "text", "p_bloco" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_criar_faixa_quartos"("p_evento_slug" "text", "p_de" integer, "p_ate" integer, "p_tipo" "text", "p_bloco" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_criar_faixa_quartos"("p_evento_slug" "text", "p_de" integer, "p_ate" integer, "p_tipo" "text", "p_bloco" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_definir_patrocinadores_cota"("p_cota_id" "uuid", "p_patrocinadores" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_definir_patrocinadores_cota"("p_cota_id" "uuid", "p_patrocinadores" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_definir_patrocinadores_cota"("p_cota_id" "uuid", "p_patrocinadores" "uuid"[]) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_empresas_da_rodada"("p_rodada" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_empresas_da_rodada"("p_rodada" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_empresas_da_rodada"("p_rodada" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_enriquecer_patrocinador"("p_id" "uuid", "p_site" "text", "p_resumo" "text", "p_o_que_vende" "text", "p_segmento" "text", "p_natureza" "text", "p_cidade" "text", "p_estado" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_enriquecer_patrocinador"("p_id" "uuid", "p_site" "text", "p_resumo" "text", "p_o_que_vende" "text", "p_segmento" "text", "p_natureza" "text", "p_cidade" "text", "p_estado" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_enriquecer_patrocinador"("p_id" "uuid", "p_site" "text", "p_resumo" "text", "p_o_que_vende" "text", "p_segmento" "text", "p_natureza" "text", "p_cidade" "text", "p_estado" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_estados_base"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_estados_base"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_estados_base"() TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_etiquetas"("p_evento_slug" "text", "p_categoria" "text", "p_origem" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_etiquetas"("p_evento_slug" "text", "p_categoria" "text", "p_origem" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_etiquetas"("p_evento_slug" "text", "p_categoria" "text", "p_origem" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_etiquetas_resumo"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_etiquetas_resumo"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_etiquetas_resumo"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_fatura_itens"("p_fatura_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_fatura_itens"("p_fatura_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_fatura_itens"("p_fatura_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_financeiro_resumo"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_financeiro_resumo"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_financeiro_resumo"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_gerar_quartos_cota"("p_patrocinador_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_gerar_quartos_cota"("p_patrocinador_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_gerar_quartos_cota"("p_patrocinador_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_gerar_quartos_todos"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_gerar_quartos_todos"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_gerar_quartos_todos"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_gerar_sessoes"("p_evento_slug" "text", "p_tipo" "text", "p_data" "date", "p_horario" time without time zone, "p_local" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_gerar_sessoes"("p_evento_slug" "text", "p_tipo" "text", "p_data" "date", "p_horario" time without time zone, "p_local" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_gerar_sessoes"("p_evento_slug" "text", "p_tipo" "text", "p_data" "date", "p_horario" time without time zone, "p_local" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_importar_gestores"("p_linhas" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_importar_gestores"("p_linhas" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_importar_gestores"("p_linhas" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_importar_pesquisa"("p_evento_slug" "text", "p_linhas" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_importar_pesquisa"("p_evento_slug" "text", "p_linhas" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_importar_pesquisa"("p_evento_slug" "text", "p_linhas" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_alocacao"("p_evento_slug" "text", "p_apenas_sem_quarto" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_alocacao"("p_evento_slug" "text", "p_apenas_sem_quarto" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_alocacao"("p_evento_slug" "text", "p_apenas_sem_quarto" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_cotas"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_cotas"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_cotas"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_equipe"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_equipe"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_equipe"() TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_eventos"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_eventos"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_eventos"() TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_faturas"("p_evento_slug" "text", "p_status" "text", "p_limite" integer, "p_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_faturas"("p_evento_slug" "text", "p_status" "text", "p_limite" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_faturas"("p_evento_slug" "text", "p_status" "text", "p_limite" integer, "p_offset" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_indicacoes"("p_evento_slug" "text", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_indicacoes"("p_evento_slug" "text", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_indicacoes"("p_evento_slug" "text", "p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_patrocinadores"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_patrocinadores"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_patrocinadores"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_pendentes"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_pendentes"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_pendentes"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_precos"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_precos"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_precos"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_prospeccao"("p_evento_slug" "text", "p_sessao_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_prospeccao"("p_evento_slug" "text", "p_sessao_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_prospeccao"("p_evento_slug" "text", "p_sessao_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_rodadas"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_rodadas"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_rodadas"() TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_sessoes"("p_evento_slug" "text", "p_tipo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_sessoes"("p_evento_slug" "text", "p_tipo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_sessoes"("p_evento_slug" "text", "p_tipo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_sugestoes"("p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_sugestoes"("p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_sugestoes"("p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_listar_usuarios_patro"("p_patrocinador_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_usuarios_patro"("p_patrocinador_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_usuarios_patro"("p_patrocinador_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_localidades_base"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_localidades_base"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_localidades_base"() TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_mailing_sessao"("p_sessao_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_mailing_sessao"("p_sessao_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_mailing_sessao"("p_sessao_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_marcar_fatura"("p_fatura_id" "uuid", "p_status" "text", "p_forma_pagamento" "text", "p_observacao" "text", "p_vencimento" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_marcar_fatura"("p_fatura_id" "uuid", "p_status" "text", "p_forma_pagamento" "text", "p_observacao" "text", "p_vencimento" "date") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_marcar_fatura"("p_fatura_id" "uuid", "p_status" "text", "p_forma_pagamento" "text", "p_observacao" "text", "p_vencimento" "date") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_marcar_prospeccao"("p_id" "uuid", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_marcar_prospeccao"("p_id" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_marcar_prospeccao"("p_id" "uuid", "p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_match_jantar"("p_sessao_id" "uuid", "p_limite" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_match_jantar"("p_sessao_id" "uuid", "p_limite" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_match_jantar"("p_sessao_id" "uuid", "p_limite" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_pesquisa_areas"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_pesquisa_areas"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_pesquisa_areas"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_pesquisa_por_area"("p_evento_slug" "text", "p_area" "text", "p_intencao" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_pesquisa_por_area"("p_evento_slug" "text", "p_area" "text", "p_intencao" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_pesquisa_por_area"("p_evento_slug" "text", "p_area" "text", "p_intencao" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_pesquisa_resumo"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_pesquisa_resumo"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_pesquisa_resumo"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_prospeccao_base"("p_evento_slug" "text", "p_excluir_fornecedores" boolean, "p_excluir_empresas" "text"[], "p_excluir_convidados" boolean, "p_tipo_sessao" "text", "p_limite" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_prospeccao_base"("p_evento_slug" "text", "p_excluir_fornecedores" boolean, "p_excluir_empresas" "text"[], "p_excluir_convidados" boolean, "p_tipo_sessao" "text", "p_limite" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_prospeccao_base"("p_evento_slug" "text", "p_excluir_fornecedores" boolean, "p_excluir_empresas" "text"[], "p_excluir_convidados" boolean, "p_tipo_sessao" "text", "p_limite" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_quartos_livres"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_quartos_livres"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_quartos_livres"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_recalcular_faturas"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_recalcular_faturas"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_recalcular_faturas"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_registrar_sugestao"("p_tipo" "text", "p_gestor_id" "uuid", "p_empresa" "text", "p_campo" "text", "p_valor_atual" "text", "p_valor_sugerido" "text", "p_confianca" numeric, "p_fonte" "text", "p_justificativa" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_registrar_sugestao"("p_tipo" "text", "p_gestor_id" "uuid", "p_empresa" "text", "p_campo" "text", "p_valor_atual" "text", "p_valor_sugerido" "text", "p_confianca" numeric, "p_fonte" "text", "p_justificativa" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_registrar_sugestao"("p_tipo" "text", "p_gestor_id" "uuid", "p_empresa" "text", "p_campo" "text", "p_valor_atual" "text", "p_valor_sugerido" "text", "p_confianca" numeric, "p_fonte" "text", "p_justificativa" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_rel_checkins_detalhe"("p_evento_slug" "text", "p_empresa" "text", "p_limite" integer, "p_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_rel_checkins_detalhe"("p_evento_slug" "text", "p_empresa" "text", "p_limite" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_rel_checkins_detalhe"("p_evento_slug" "text", "p_empresa" "text", "p_limite" integer, "p_offset" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_rel_checkins_resumo"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_rel_checkins_resumo"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_rel_checkins_resumo"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_rel_mailing"("p_evento_slug" "text", "p_limite" integer, "p_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_rel_mailing"("p_evento_slug" "text", "p_limite" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_rel_mailing"("p_evento_slug" "text", "p_limite" integer, "p_offset" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_rel_painel"("p_evento_slug" "text", "p_limite" integer, "p_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_rel_painel"("p_evento_slug" "text", "p_limite" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_rel_painel"("p_evento_slug" "text", "p_limite" integer, "p_offset" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_rel_pesquisa"("p_evento_slug" "text", "p_limite" integer, "p_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_rel_pesquisa"("p_evento_slug" "text", "p_limite" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_rel_pesquisa"("p_evento_slug" "text", "p_limite" integer, "p_offset" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_remover_convidado_sessao"("p_sessao_id" "uuid", "p_participante_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_remover_convidado_sessao"("p_sessao_id" "uuid", "p_participante_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_remover_convidado_sessao"("p_sessao_id" "uuid", "p_participante_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_remover_cota"("p_cota_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_remover_cota"("p_cota_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_remover_cota"("p_cota_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_remover_membro"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_remover_membro"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_remover_membro"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_remover_patrocinador"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_remover_patrocinador"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_remover_patrocinador"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_remover_preco"("p_preco_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_remover_preco"("p_preco_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_remover_preco"("p_preco_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_remover_quartos_livres"("p_evento_slug" "text", "p_tipo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_remover_quartos_livres"("p_evento_slug" "text", "p_tipo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_remover_quartos_livres"("p_evento_slug" "text", "p_tipo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_remover_sessao"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_remover_sessao"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_remover_sessao"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_remover_usuario_patro"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_remover_usuario_patro"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_remover_usuario_patro"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_resumo_quartos"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_resumo_quartos"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_resumo_quartos"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_salvar_cota"("p_evento_slug" "text", "p_nome" "text", "p_ordem" integer, "p_quartos" "jsonb", "p_vagas_mesa" integer, "p_reuniao" boolean, "p_jantar" boolean, "p_prazo_indicacao" "date", "p_janela_horas" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_salvar_cota"("p_evento_slug" "text", "p_nome" "text", "p_ordem" integer, "p_quartos" "jsonb", "p_vagas_mesa" integer, "p_reuniao" boolean, "p_jantar" boolean, "p_prazo_indicacao" "date", "p_janela_horas" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_salvar_cota"("p_evento_slug" "text", "p_nome" "text", "p_ordem" integer, "p_quartos" "jsonb", "p_vagas_mesa" integer, "p_reuniao" boolean, "p_jantar" boolean, "p_prazo_indicacao" "date", "p_janela_horas" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_salvar_evento"("p_slug" "text", "p_nome" "text", "p_local" "text", "p_data_inicio" "date", "p_data_fim" "date", "p_status" "text", "p_prazo_contrato" "date", "p_prazo_rooming" "date", "p_prazo_cancelamento" "date", "p_sympla_event_id" "text", "p_cota_unica" boolean, "p_escolha_abre_em" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_salvar_evento"("p_slug" "text", "p_nome" "text", "p_local" "text", "p_data_inicio" "date", "p_data_fim" "date", "p_status" "text", "p_prazo_contrato" "date", "p_prazo_rooming" "date", "p_prazo_cancelamento" "date", "p_sympla_event_id" "text", "p_cota_unica" boolean, "p_escolha_abre_em" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_salvar_evento"("p_slug" "text", "p_nome" "text", "p_local" "text", "p_data_inicio" "date", "p_data_fim" "date", "p_status" "text", "p_prazo_contrato" "date", "p_prazo_rooming" "date", "p_prazo_cancelamento" "date", "p_sympla_event_id" "text", "p_cota_unica" boolean, "p_escolha_abre_em" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_salvar_membro"("p_email" "text", "p_nome" "text", "p_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_salvar_membro"("p_email" "text", "p_nome" "text", "p_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_salvar_membro"("p_email" "text", "p_nome" "text", "p_role" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_salvar_patrocinador"("p_evento_slug" "text", "p_empresa" "text", "p_cota_nome" "text", "p_cnpj" "text", "p_segmento" "text", "p_o_que_vende" "text", "p_quartos_extras" integer, "p_vagas_mesa_override" integer, "p_status" "text", "p_site" "text", "p_resumo" "text", "p_natureza" "text", "p_cidade" "text", "p_estado" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_salvar_patrocinador"("p_evento_slug" "text", "p_empresa" "text", "p_cota_nome" "text", "p_cnpj" "text", "p_segmento" "text", "p_o_que_vende" "text", "p_quartos_extras" integer, "p_vagas_mesa_override" integer, "p_status" "text", "p_site" "text", "p_resumo" "text", "p_natureza" "text", "p_cidade" "text", "p_estado" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_salvar_patrocinador"("p_evento_slug" "text", "p_empresa" "text", "p_cota_nome" "text", "p_cnpj" "text", "p_segmento" "text", "p_o_que_vende" "text", "p_quartos_extras" integer, "p_vagas_mesa_override" integer, "p_status" "text", "p_site" "text", "p_resumo" "text", "p_natureza" "text", "p_cidade" "text", "p_estado" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_salvar_preco"("p_evento_slug" "text", "p_item" "text", "p_valor" numeric, "p_descricao" "text", "p_idade_min" integer, "p_idade_max" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_salvar_preco"("p_evento_slug" "text", "p_item" "text", "p_valor" numeric, "p_descricao" "text", "p_idade_min" integer, "p_idade_max" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_salvar_preco"("p_evento_slug" "text", "p_item" "text", "p_valor" numeric, "p_descricao" "text", "p_idade_min" integer, "p_idade_max" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_salvar_prospeccao"("p_evento_slug" "text", "p_sessao_id" "uuid", "p_itens" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_salvar_prospeccao"("p_evento_slug" "text", "p_sessao_id" "uuid", "p_itens" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_salvar_prospeccao"("p_evento_slug" "text", "p_sessao_id" "uuid", "p_itens" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_salvar_sessao"("p_evento_slug" "text", "p_patrocinador_id" "uuid", "p_tipo" "text", "p_data" "date", "p_horario" time without time zone, "p_local" "text", "p_vagas" integer, "p_sessao_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_salvar_sessao"("p_evento_slug" "text", "p_patrocinador_id" "uuid", "p_tipo" "text", "p_data" "date", "p_horario" time without time zone, "p_local" "text", "p_vagas" integer, "p_sessao_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_salvar_sessao"("p_evento_slug" "text", "p_patrocinador_id" "uuid", "p_tipo" "text", "p_data" "date", "p_horario" time without time zone, "p_local" "text", "p_vagas" integer, "p_sessao_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."admin_salvar_usuario_patro"("p_patrocinador_id" "uuid", "p_email" "text", "p_nome" "text", "p_telefone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_salvar_usuario_patro"("p_patrocinador_id" "uuid", "p_email" "text", "p_nome" "text", "p_telefone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_salvar_usuario_patro"("p_patrocinador_id" "uuid", "p_email" "text", "p_nome" "text", "p_telefone" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."checkin_cadastrar"("p_evento_slug" "text", "p_nome" "text", "p_empresa" "text", "p_email" "text", "p_telefone" "text", "p_cargo" "text", "p_categoria" "text", "p_local" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."checkin_cadastrar"("p_evento_slug" "text", "p_nome" "text", "p_empresa" "text", "p_email" "text", "p_telefone" "text", "p_cargo" "text", "p_categoria" "text", "p_local" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."checkin_cadastrar"("p_evento_slug" "text", "p_nome" "text", "p_empresa" "text", "p_email" "text", "p_telefone" "text", "p_cargo" "text", "p_categoria" "text", "p_local" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."checkin_desfazer"("p_checkin_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."checkin_desfazer"("p_checkin_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."checkin_desfazer"("p_checkin_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."checkin_listar"("p_evento_slug" "text", "p_termo" "text", "p_so_pendentes" boolean, "p_limite" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."checkin_listar"("p_evento_slug" "text", "p_termo" "text", "p_so_pendentes" boolean, "p_limite" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."checkin_listar"("p_evento_slug" "text", "p_termo" "text", "p_so_pendentes" boolean, "p_limite" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."checkin_registrar"("p_evento_slug" "text", "p_pessoa_key" "text", "p_local" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."checkin_registrar"("p_evento_slug" "text", "p_pessoa_key" "text", "p_local" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."checkin_registrar"("p_evento_slug" "text", "p_pessoa_key" "text", "p_local" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."checkin_resumo"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."checkin_resumo"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."checkin_resumo"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."is_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."is_admin"() TO "service_role";
GRANT ALL ON FUNCTION "gestao"."is_admin"() TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."is_staff"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."is_staff"() TO "service_role";
GRANT ALL ON FUNCTION "gestao"."is_staff"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."is_staff"() TO "anon";



REVOKE ALL ON FUNCTION "gestao"."jantar_avulso"("p_jantar_id" "uuid", "p_nome" "text", "p_empresa" "text", "p_email" "text", "p_telefone" "text", "p_cargo" "text", "p_rotulo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_avulso"("p_jantar_id" "uuid", "p_nome" "text", "p_empresa" "text", "p_email" "text", "p_telefone" "text", "p_cargo" "text", "p_rotulo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_avulso"("p_jantar_id" "uuid", "p_nome" "text", "p_empresa" "text", "p_email" "text", "p_telefone" "text", "p_cargo" "text", "p_rotulo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."jantar_base"("p_jantar_id" "uuid", "p_excluir_fornecedores" boolean, "p_excluir_convidados" boolean, "p_limite" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_base"("p_jantar_id" "uuid", "p_excluir_fornecedores" boolean, "p_excluir_convidados" boolean, "p_limite" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_base"("p_jantar_id" "uuid", "p_excluir_fornecedores" boolean, "p_excluir_convidados" boolean, "p_limite" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."jantar_convidados_listar"("p_jantar_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_convidados_listar"("p_jantar_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_convidados_listar"("p_jantar_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."jantar_empresas_sem_convite"("p_limite" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_empresas_sem_convite"("p_limite" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_empresas_sem_convite"("p_limite" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."jantar_estatisticas_gestores"("p_limite" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_estatisticas_gestores"("p_limite" integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_estatisticas_gestores"("p_limite" integer) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."jantar_listar"("p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_listar"("p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_listar"("p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."jantar_marcar_convidado"("p_id" "uuid", "p_status" "text", "p_observacao" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_marcar_convidado"("p_id" "uuid", "p_status" "text", "p_observacao" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_marcar_convidado"("p_id" "uuid", "p_status" "text", "p_observacao" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."jantar_obter"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_obter"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_obter"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."jantar_remover"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_remover"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_remover"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."jantar_remover_convidado"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_remover_convidado"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_remover_convidado"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."jantar_salvar"("p_patrocinador_nome" "text", "p_id" "uuid", "p_data" "date", "p_horario" time without time zone, "p_local" "text", "p_patrocinador_site" "text", "p_perfil_convidado" "text", "p_observacoes" "text", "p_abrangencia" "text", "p_capacidade" integer, "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_salvar"("p_patrocinador_nome" "text", "p_id" "uuid", "p_data" "date", "p_horario" time without time zone, "p_local" "text", "p_patrocinador_site" "text", "p_perfil_convidado" "text", "p_observacoes" "text", "p_abrangencia" "text", "p_capacidade" integer, "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_salvar"("p_patrocinador_nome" "text", "p_id" "uuid", "p_data" "date", "p_horario" time without time zone, "p_local" "text", "p_patrocinador_site" "text", "p_perfil_convidado" "text", "p_observacoes" "text", "p_abrangencia" "text", "p_capacidade" integer, "p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."jantar_salvar_selecao"("p_jantar_id" "uuid", "p_itens" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_salvar_selecao"("p_jantar_id" "uuid", "p_itens" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_salvar_selecao"("p_jantar_id" "uuid", "p_itens" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."listar_cotas"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."listar_cotas"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."listar_cotas"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."meus_patrocinadores"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."meus_patrocinadores"() TO "service_role";
GRANT ALL ON FUNCTION "gestao"."meus_patrocinadores"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."meus_patrocinadores"() TO "anon";



REVOKE ALL ON FUNCTION "gestao"."norm_cpf"("v" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."norm_cpf"("v" "text") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."norm_cpf"("v" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."norm_doc"("v" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."norm_doc"("v" "text") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."norm_doc"("v" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."part_autocadastro"("p_evento_slug" "text", "p_nome" "text", "p_email" "text", "p_empresa" "text", "p_cargo" "text", "p_telefone" "text", "p_cnpj" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."part_autocadastro"("p_evento_slug" "text", "p_nome" "text", "p_email" "text", "p_empresa" "text", "p_cargo" "text", "p_telefone" "text", "p_cnpj" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."part_autocadastro"("p_evento_slug" "text", "p_nome" "text", "p_email" "text", "p_empresa" "text", "p_cargo" "text", "p_telefone" "text", "p_cnpj" "text") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."part_autocadastro"("p_evento_slug" "text", "p_nome" "text", "p_email" "text", "p_empresa" "text", "p_cargo" "text", "p_telefone" "text", "p_cnpj" "text") TO "anon";



REVOKE ALL ON FUNCTION "gestao"."part_calcular_fatura"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."part_calcular_fatura"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."part_calcular_fatura"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."part_listar_rooming"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."part_listar_rooming"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."part_listar_rooming"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."part_meu_status"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."part_meu_status"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."part_meu_status"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."part_minha_fatura"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."part_minha_fatura"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."part_minha_fatura"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."part_previa_fatura"("p_evento_slug" "text", "p_acompanhantes" "jsonb", "p_usa_transfer" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."part_previa_fatura"("p_evento_slug" "text", "p_acompanhantes" "jsonb", "p_usa_transfer" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."part_previa_fatura"("p_evento_slug" "text", "p_acompanhantes" "jsonb", "p_usa_transfer" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."part_salvar_rooming"("p_evento_slug" "text", "p_acompanhantes" "jsonb", "p_usa_transfer" boolean, "p_transfer_origem" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."part_salvar_rooming"("p_evento_slug" "text", "p_acompanhantes" "jsonb", "p_usa_transfer" boolean, "p_transfer_origem" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."part_salvar_rooming"("p_evento_slug" "text", "p_acompanhantes" "jsonb", "p_usa_transfer" boolean, "p_transfer_origem" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."patro_cancelar_quarto_extra"("p_reserva_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_cancelar_quarto_extra"("p_reserva_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."patro_cancelar_quarto_extra"("p_reserva_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."patro_comprar_quarto"("p_patrocinador_id" "uuid", "p_tipo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_comprar_quarto"("p_patrocinador_id" "uuid", "p_tipo" "text") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."patro_comprar_quarto"("p_patrocinador_id" "uuid", "p_tipo" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."patro_convidados_disponiveis"("p_sessao_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_convidados_disponiveis"("p_sessao_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."patro_convidados_disponiveis"("p_sessao_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."patro_disponibilidade"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_disponibilidade"("p_evento_slug" "text") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."patro_disponibilidade"("p_evento_slug" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."patro_escolher_convidados"("p_sessao_id" "uuid", "p_participantes" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_escolher_convidados"("p_sessao_id" "uuid", "p_participantes" "uuid"[]) TO "service_role";
GRANT ALL ON FUNCTION "gestao"."patro_escolher_convidados"("p_sessao_id" "uuid", "p_participantes" "uuid"[]) TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."patro_indicar_cio"("p_patrocinador_id" "uuid", "p_nome" "text", "p_empresa" "text", "p_cargo" "text", "p_email" "text", "p_telefone" "text", "p_observacao" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_indicar_cio"("p_patrocinador_id" "uuid", "p_nome" "text", "p_empresa" "text", "p_cargo" "text", "p_email" "text", "p_telefone" "text", "p_observacao" "text") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."patro_indicar_cio"("p_patrocinador_id" "uuid", "p_nome" "text", "p_empresa" "text", "p_cargo" "text", "p_email" "text", "p_telefone" "text", "p_observacao" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."patro_listar_indicacoes"("p_patrocinador_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_listar_indicacoes"("p_patrocinador_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."patro_listar_indicacoes"("p_patrocinador_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."patro_listar_ocupantes"("p_reserva_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_listar_ocupantes"("p_reserva_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."patro_listar_ocupantes"("p_reserva_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."patro_listar_quartos"("p_patrocinador_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_listar_quartos"("p_patrocinador_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."patro_listar_quartos"("p_patrocinador_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."patro_manual"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_manual"("p_evento_slug" "text") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."patro_manual"("p_evento_slug" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."patro_meu_painel"("p_evento_slug" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_meu_painel"("p_evento_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."patro_meu_painel"("p_evento_slug" "text") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."patro_minha_vez"("p_sessao_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_minha_vez"("p_sessao_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."patro_minha_vez"("p_sessao_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."patro_minhas_sessoes"("p_patrocinador_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_minhas_sessoes"("p_patrocinador_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."patro_minhas_sessoes"("p_patrocinador_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "gestao"."patro_passar_a_vez"("p_sessao_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_passar_a_vez"("p_sessao_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."patro_passar_a_vez"("p_sessao_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."patro_salvar_quarto"("p_reserva_id" "uuid", "p_ocupantes" "jsonb", "p_usa_transfer" boolean, "p_transfer_origem" "text", "p_brinde_enviar" boolean, "p_brinde_descricao" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."patro_salvar_quarto"("p_reserva_id" "uuid", "p_ocupantes" "jsonb", "p_usa_transfer" boolean, "p_transfer_origem" "text", "p_brinde_enviar" boolean, "p_brinde_descricao" "text") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."patro_salvar_quarto"("p_reserva_id" "uuid", "p_ocupantes" "jsonb", "p_usa_transfer" boolean, "p_transfer_origem" "text", "p_brinde_enviar" boolean, "p_brinde_descricao" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."pode_ver_patrocinador"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."pode_ver_patrocinador"("p_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."pode_ver_patrocinador"("p_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "gestao"."touch_updated_at"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."touch_updated_at"() TO "service_role";
GRANT ALL ON FUNCTION "gestao"."touch_updated_at"() TO "authenticated";



GRANT ALL ON TABLE "gestao"."admins" TO "anon";
GRANT ALL ON TABLE "gestao"."admins" TO "authenticated";
GRANT ALL ON TABLE "gestao"."admins" TO "service_role";



GRANT ALL ON TABLE "gestao"."auditoria" TO "anon";
GRANT ALL ON TABLE "gestao"."auditoria" TO "authenticated";
GRANT ALL ON TABLE "gestao"."auditoria" TO "service_role";



GRANT ALL ON TABLE "gestao"."brindes" TO "anon";
GRANT ALL ON TABLE "gestao"."brindes" TO "authenticated";
GRANT ALL ON TABLE "gestao"."brindes" TO "service_role";



GRANT ALL ON TABLE "gestao"."checkins" TO "anon";
GRANT ALL ON TABLE "gestao"."checkins" TO "authenticated";
GRANT ALL ON TABLE "gestao"."checkins" TO "service_role";



GRANT ALL ON TABLE "gestao"."contratos" TO "anon";
GRANT ALL ON TABLE "gestao"."contratos" TO "authenticated";
GRANT ALL ON TABLE "gestao"."contratos" TO "service_role";



GRANT ALL ON TABLE "gestao"."cota_quartos" TO "anon";
GRANT ALL ON TABLE "gestao"."cota_quartos" TO "authenticated";
GRANT ALL ON TABLE "gestao"."cota_quartos" TO "service_role";



GRANT ALL ON TABLE "gestao"."cotas" TO "anon";
GRANT ALL ON TABLE "gestao"."cotas" TO "authenticated";
GRANT ALL ON TABLE "gestao"."cotas" TO "service_role";



GRANT ALL ON TABLE "gestao"."eventos" TO "anon";
GRANT ALL ON TABLE "gestao"."eventos" TO "authenticated";
GRANT ALL ON TABLE "gestao"."eventos" TO "service_role";



GRANT ALL ON TABLE "gestao"."fatura_itens" TO "anon";
GRANT ALL ON TABLE "gestao"."fatura_itens" TO "authenticated";
GRANT ALL ON TABLE "gestao"."fatura_itens" TO "service_role";



GRANT ALL ON TABLE "gestao"."faturas" TO "anon";
GRANT ALL ON TABLE "gestao"."faturas" TO "authenticated";
GRANT ALL ON TABLE "gestao"."faturas" TO "service_role";



GRANT ALL ON TABLE "gestao"."gestores" TO "anon";
GRANT ALL ON TABLE "gestao"."gestores" TO "authenticated";
GRANT ALL ON TABLE "gestao"."gestores" TO "service_role";



GRANT ALL ON TABLE "gestao"."gestores_historico" TO "anon";
GRANT ALL ON TABLE "gestao"."gestores_historico" TO "authenticated";
GRANT ALL ON TABLE "gestao"."gestores_historico" TO "service_role";



GRANT ALL ON TABLE "gestao"."importacoes" TO "anon";
GRANT ALL ON TABLE "gestao"."importacoes" TO "authenticated";
GRANT ALL ON TABLE "gestao"."importacoes" TO "service_role";



GRANT ALL ON TABLE "gestao"."indicacoes" TO "anon";
GRANT ALL ON TABLE "gestao"."indicacoes" TO "authenticated";
GRANT ALL ON TABLE "gestao"."indicacoes" TO "service_role";



GRANT ALL ON TABLE "gestao"."jantar_convidados" TO "anon";
GRANT ALL ON TABLE "gestao"."jantar_convidados" TO "authenticated";
GRANT ALL ON TABLE "gestao"."jantar_convidados" TO "service_role";



GRANT ALL ON TABLE "gestao"."jantares" TO "anon";
GRANT ALL ON TABLE "gestao"."jantares" TO "authenticated";
GRANT ALL ON TABLE "gestao"."jantares" TO "service_role";



GRANT ALL ON TABLE "gestao"."notificacoes" TO "anon";
GRANT ALL ON TABLE "gestao"."notificacoes" TO "authenticated";
GRANT ALL ON TABLE "gestao"."notificacoes" TO "service_role";



GRANT ALL ON TABLE "gestao"."ocupantes" TO "anon";
GRANT ALL ON TABLE "gestao"."ocupantes" TO "authenticated";
GRANT ALL ON TABLE "gestao"."ocupantes" TO "service_role";



GRANT ALL ON TABLE "gestao"."participante_perfil" TO "anon";
GRANT ALL ON TABLE "gestao"."participante_perfil" TO "authenticated";
GRANT ALL ON TABLE "gestao"."participante_perfil" TO "service_role";



GRANT ALL ON TABLE "gestao"."participantes" TO "anon";
GRANT ALL ON TABLE "gestao"."participantes" TO "authenticated";
GRANT ALL ON TABLE "gestao"."participantes" TO "service_role";



GRANT ALL ON TABLE "gestao"."patrocinadores" TO "anon";
GRANT ALL ON TABLE "gestao"."patrocinadores" TO "authenticated";
GRANT ALL ON TABLE "gestao"."patrocinadores" TO "service_role";



GRANT ALL ON TABLE "gestao"."precos" TO "anon";
GRANT ALL ON TABLE "gestao"."precos" TO "authenticated";
GRANT ALL ON TABLE "gestao"."precos" TO "service_role";



GRANT ALL ON TABLE "gestao"."prospeccoes" TO "anon";
GRANT ALL ON TABLE "gestao"."prospeccoes" TO "authenticated";
GRANT ALL ON TABLE "gestao"."prospeccoes" TO "service_role";



GRANT ALL ON TABLE "gestao"."quartos" TO "anon";
GRANT ALL ON TABLE "gestao"."quartos" TO "authenticated";
GRANT ALL ON TABLE "gestao"."quartos" TO "service_role";



GRANT ALL ON TABLE "gestao"."reservas" TO "anon";
GRANT ALL ON TABLE "gestao"."reservas" TO "authenticated";
GRANT ALL ON TABLE "gestao"."reservas" TO "service_role";



GRANT ALL ON TABLE "gestao"."sessao_convidados" TO "anon";
GRANT ALL ON TABLE "gestao"."sessao_convidados" TO "authenticated";
GRANT ALL ON TABLE "gestao"."sessao_convidados" TO "service_role";



GRANT ALL ON TABLE "gestao"."sessoes" TO "anon";
GRANT ALL ON TABLE "gestao"."sessoes" TO "authenticated";
GRANT ALL ON TABLE "gestao"."sessoes" TO "service_role";



GRANT ALL ON TABLE "gestao"."sugestoes_ia" TO "anon";
GRANT ALL ON TABLE "gestao"."sugestoes_ia" TO "authenticated";
GRANT ALL ON TABLE "gestao"."sugestoes_ia" TO "service_role";



GRANT ALL ON TABLE "gestao"."usuarios_patrocinador" TO "anon";
GRANT ALL ON TABLE "gestao"."usuarios_patrocinador" TO "authenticated";
GRANT ALL ON TABLE "gestao"."usuarios_patrocinador" TO "service_role";



GRANT ALL ON TABLE "gestao"."v_checkins_resumo" TO "anon";
GRANT ALL ON TABLE "gestao"."v_checkins_resumo" TO "authenticated";
GRANT ALL ON TABLE "gestao"."v_checkins_resumo" TO "service_role";



GRANT ALL ON TABLE "gestao"."v_disponibilidade_quartos" TO "anon";
GRANT ALL ON TABLE "gestao"."v_disponibilidade_quartos" TO "authenticated";
GRANT ALL ON TABLE "gestao"."v_disponibilidade_quartos" TO "service_role";



GRANT ALL ON TABLE "gestao"."v_esperados" TO "anon";
GRANT ALL ON TABLE "gestao"."v_esperados" TO "authenticated";
GRANT ALL ON TABLE "gestao"."v_esperados" TO "service_role";



GRANT ALL ON TABLE "gestao"."v_etiquetas" TO "anon";
GRANT ALL ON TABLE "gestao"."v_etiquetas" TO "authenticated";
GRANT ALL ON TABLE "gestao"."v_etiquetas" TO "service_role";



GRANT ALL ON TABLE "gestao"."v_ordem_escolha" TO "anon";
GRANT ALL ON TABLE "gestao"."v_ordem_escolha" TO "authenticated";
GRANT ALL ON TABLE "gestao"."v_ordem_escolha" TO "service_role";



GRANT ALL ON TABLE "gestao"."v_painel_participantes" TO "anon";
GRANT ALL ON TABLE "gestao"."v_painel_participantes" TO "authenticated";
GRANT ALL ON TABLE "gestao"."v_painel_participantes" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "gestao" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "gestao" GRANT ALL ON FUNCTIONS TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "gestao" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "gestao" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "gestao" GRANT ALL ON TABLES TO "service_role";




