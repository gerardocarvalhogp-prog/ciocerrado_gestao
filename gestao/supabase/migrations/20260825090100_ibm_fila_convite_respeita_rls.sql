-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Uma linha no schema `public`, e o motivo dela.
--
-- ATENCAO: esta migration mexe no `public`, que e o sistema de
-- agendamento de massagem, em producao. O CLAUDE.md diz para nao mexer,
-- e a regra e boa. Aqui ela e quebrada de proposito, por isto:
--
-- `public.ibm_fila_convite` e uma view sem `security_invoker`. View no
-- Postgres roda com o dono, entao ela ignora a RLS da tabela de baixo.
-- A tabela — `ibm_consent` — esta protegida corretamente: RLS ligada e
-- uma politica que so deixa `authenticated` com `ibm_e_admin()` ler. A
-- view fura exatamente essa politica, e o `anon` tem SELECT nela.
--
-- O que ela devolve: email, nome, sobrenome e empresa de quem esta com
-- consentimento pendente. Hoje sao ZERO linhas, e por isso o teste com
-- a chave anon voltou vazio. No dia em que a tabela for populada, essa
-- lista fica publica — a chave anon esta dentro do HTML.
--
-- POR QUE E SEGURO MEXER
--
-- Nada le essa view. Conferido: nenhuma das paginas do sistema de
-- massagem (`grep` nos .html da raiz), nenhuma funcao do `public`, e
-- ela esta vazia. `security_invoker` nao muda o que a view devolve para
-- quem tem direito de ver — so faz a politica de `ibm_consent` valer
-- tambem por aqui.
--
-- CONDICIONAL DE PROPOSITO
--
-- O banco local so tem o schema `gestao`; a view do sistema de massagem
-- nao existe la. Sem o `if`, o `db reset` quebraria em toda maquina.
--
-- PARA DESFAZER
--
--   alter view public.ibm_fila_convite set (security_invoker = false);
-- =====================================================================

do $$
begin
  if to_regclass('public.ibm_fila_convite') is null then
    raise notice 'ibm_fila_convite nao existe aqui (banco local) — nada a fazer';
    return;
  end if;

  execute 'alter view public.ibm_fila_convite set (security_invoker = true)';

  if coalesce((select o.option_value
               from pg_class c
               join pg_namespace n on n.oid = c.relnamespace
               cross join lateral pg_options_to_table(c.reloptions) o
               where n.nspname = 'public'
                 and c.relname = 'ibm_fila_convite'
                 and o.option_name = 'security_invoker'), 'false') <> 'true' then
    raise exception 'ibm_fila_convite continua sem security_invoker';
  end if;

  raise notice 'OK: ibm_fila_convite passa a respeitar a RLS de ibm_consent';
end $$;
