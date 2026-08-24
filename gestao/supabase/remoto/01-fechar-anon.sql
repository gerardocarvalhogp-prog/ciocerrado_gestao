-- =====================================================================
-- CORRECAO PARA O BANCO HOSPEDADO  ·  fechar execucao por anon
--
-- NAO e uma migration. O banco remoto seguiu um caminho proprio e as
-- migrations locais NAO devem ser aplicadas la (ver supabase/remoto/LEIA-ME.md).
-- Este arquivo e cirurgico: mexe so em permissao, nao em logica.
--
-- O PROBLEMA, medido no dump do proprio remoto:
--
--   101 funcoes admin_/patro_/jantar_/checkin_ tem GRANT explicito
--   para anon, e ainda existe
--     ALTER DEFAULT PRIVILEGES ... GRANT ALL ON FUNCTIONS TO anon
--   entao toda funcao nova nasce aberta.
--
-- A chave anon e publica: esta embutida nos cinco .html. Hoje qualquer
-- pessoa com essa chave pode chamar admin_aprovar_participante ou
-- admin_remover_membro direto na API REST.
--
-- Na pratica o dano e contido porque toda funcao chama _exige_admin()
-- na primeira linha e levanta excecao. Mas isso e a segunda tranca
-- trabalhando sozinha.
--
-- ROLLBACK: se algo quebrar, o bloco no fim deste arquivo mostra como
-- devolver o grant.
-- =====================================================================

begin;

-- 1. Corta a raiz. PUBLIC entra junto: no Postgres a funcao nasce com
--    EXECUTE para PUBLIC e o anon herda por ali — revogar so de anon
--    nao resolve.
alter default privileges in schema gestao revoke execute on functions from public;
alter default privileges in schema gestao revoke execute on functions from anon;

revoke execute on all functions in schema gestao from public;
revoke execute on all functions in schema gestao from anon;

-- 2. Tirar de PUBLIC tirou de todos; devolve a quem precisa.
grant execute on all functions in schema gestao to authenticated;
grant execute on all functions in schema gestao to service_role;

-- 3. O minimo que o anon precisa.
--    part_autocadastro  · roda DESLOGADO na tela de login do rooming
--    is_staff           · avaliada DENTRO das policies de RLS
--    meus_patrocinadores· idem
do $$
declare f record; n int := 0;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'gestao'
      and p.proname in ('part_autocadastro','is_staff','meus_patrocinadores')
  loop
    execute format('grant execute on function %s to anon', f.sig);
    n := n + 1;
  end loop;
  raise notice 'anon liberado em % funcao(oes)', n;
end $$;

-- 4. Falha em vez de passar calado.
do $$
declare v_sobrou text; v_faltou text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_sobrou
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'gestao'
    and has_function_privilege('anon', p.oid, 'EXECUTE')
    and (p.proname like 'admin%' or p.proname like 'patro%'
      or p.proname like 'jantar%' or p.proname like 'checkin%');
  if v_sobrou is not null then
    raise exception 'anon ainda executa: %', v_sobrou;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_faltou
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'gestao'
    and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and (p.proname like 'admin%' or p.proname like 'patro%'
      or p.proname like 'jantar%' or p.proname like 'checkin%'
      or p.proname like 'part%');
  if v_faltou is not null then
    raise exception 'authenticated perdeu acesso a: %', v_faltou;
  end if;

  raise notice 'OK: anon fechado, authenticated preservado';
end $$;

commit;

-- ---------------------------------------------------------------------
-- ROLLBACK (so se precisar desfazer):
--
--   grant execute on all functions in schema gestao to anon;
--   alter default privileges in schema gestao grant execute on functions to anon;
-- ---------------------------------------------------------------------
