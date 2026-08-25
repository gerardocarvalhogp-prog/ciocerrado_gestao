-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Tira o acesso direto as tabelas tambem do papel `authenticated`.
--
-- POR QUE
--
-- Magic link nao filtra ninguem: qualquer pessoa que digite um e-mail e
-- clique no link vira `authenticated`. Nao vira admin, nao vira
-- patrocinador — mas vira `authenticated`, e ate agora esse papel tinha
-- `GRANT ALL` nas 29 tabelas do schema.
--
-- O que segurava era so a RLS. Ela esta certa: 37 politicas, todas
-- escopadas, conferidas uma a uma. Mas isso deixa a seguranca inteira
-- apoiada numa camada so. Uma politica escrita errada no futuro — ou
-- uma tabela nova criada sem RLS — vira vazamento no mesmo dia.
--
-- As telas nao precisam disso. Nao ha um unico `.from(` nos cinco
-- .html: tudo passa por RPC, e as 137 funcoes continuam liberadas para
-- `authenticated`. Conferido antes de escrever: as 11 funcoes que NAO
-- sao SECURITY DEFINER sao auxiliares puras (norm_doc, _porte_*,
-- _rank_*, touch_updated_at) e nenhuma delas toca tabela.
--
-- Depois disto, ler dado do schema `gestao` exige passar por uma
-- funcao, e toda funcao checa papel na primeira linha.
--
-- SE ALGUMA TELA QUEBRAR, o sintoma sera "permission denied for table
-- X" numa chamada `.from("X")` que eu nao achei. O conserto e trocar a
-- chamada por RPC, nao devolver o grant.
-- =====================================================================

set search_path = gestao, public;

-- `for role postgres` explicito: e ele quem concedeu (esta assim no
-- dump), e sem isso o alvo seria o papel da conexao.
alter default privileges for role postgres in schema gestao
  revoke all on tables from authenticated;
revoke all on all tables in schema gestao from authenticated;

-- O `usage` no schema continua: sem ele o PostgREST nao acha nem as
-- funcoes.
grant usage on schema gestao to authenticated;

-- ---------------------------------------------------------------------
-- Falha em vez de passar calado.
-- ---------------------------------------------------------------------
do $$
declare v_tabelas text; v_funcoes int;
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_tabelas
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'gestao' and c.relkind in ('r','v')
    and (has_table_privilege('authenticated', c.oid, 'SELECT')
      or has_table_privilege('anon', c.oid, 'SELECT'));
  if v_tabelas is not null then
    raise exception 'ainda ha leitura direta de tabela: %', v_tabelas;
  end if;

  -- e o caminho que importa continua aberto
  select count(*) into v_funcoes
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'gestao'
    and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if v_funcoes < 130 then
    raise exception 'authenticated perdeu funcoes: sobraram %', v_funcoes;
  end if;

  raise notice 'OK: % funcoes para authenticated, nenhuma tabela direta', v_funcoes;
end $$;
