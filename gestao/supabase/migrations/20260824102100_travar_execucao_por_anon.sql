-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Fecha a execucao de funcoes para o papel `anon`.
--
-- PRECISA SER A ULTIMA MIGRATION. Se vier antes de qualquer arquivo que
-- crie funcao, o efeito e desfeito — foi exatamente o que aconteceu ate
-- aqui.
--
-- O QUE ESTAVA ERRADO
--
-- O schema base declara:
--     alter default privileges in schema gestao
--       grant all on functions to anon, authenticated, service_role;
--
-- Com isso, TODA funcao criada depois nasce executavel por anon. Os
-- blocos `revoke ... from anon` no fim de cada arquivo de funcao
-- revogavam corretamente, mas os arquivos seguintes criavam (e o
-- correcoes-01 chega a dropar e recriar) funcoes que renasciam
-- liberadas. Resultado medido no banco local: as 129 funcoes do schema
-- executaveis por anon, incluindo admin_aprovar_participante e
-- admin_remover_membro.
--
-- Na pratica ninguem virava admin com isso: toda funcao administrativa
-- chama _exige_admin()/exigir_admin() na primeira linha e levanta
-- excecao. Mas isso e a segunda tranca, nao a primeira — e com a chave
-- anon publica em cinco .html, a primeira tranca importa.
--
-- QUEM CONTINUA LIBERADO E POR QUE
--
--   part_autocadastro     · roda DESLOGADO, na tela de login do rooming
--                           ("ainda nao tenho cadastro"). Sem ela, quem
--                           nao esta na base nao consegue se inscrever.
--   is_staff              · avaliada DENTRO das policies de RLS
--   meus_patrocinadores   · idem
--
-- As duas ultimas sao security definer: o corpo roda como o dono, mas o
-- papel que consulta precisa poder chama-las, senao um SELECT sujeito a
-- policy falha com "permission denied" em vez de simplesmente nao
-- devolver linha.
-- =====================================================================

set search_path = gestao, public;

-- 1. Corta a raiz. PUBLIC entra junto de proposito: no Postgres, funcao
--    nasce com EXECUTE para PUBLIC, e `anon` herda por ali. Revogar so
--    de anon nao adianta — foi o que a primeira versao desta migration
--    tentou, e o banco continuou liberado.
alter default privileges in schema gestao
  revoke execute on functions from public;
alter default privileges in schema gestao
  revoke execute on functions from anon;

-- 2. Revoga o que ja existe, nas duas frentes.
revoke execute on all functions in schema gestao from public;
revoke execute on all functions in schema gestao from anon;

-- 3. Tirar de PUBLIC tirou de todo mundo; devolve a quem precisa.
grant execute on all functions in schema gestao to authenticated;
grant execute on all functions in schema gestao to service_role;

-- 4. Devolve o minimo necessario ao anon.
do $$
declare f record; n int := 0;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
    where n2.nspname = 'gestao'
      and p.proname in ('part_autocadastro','is_staff','meus_patrocinadores')
  loop
    execute format('grant execute on function %s to anon', f.sig);
    n := n + 1;
  end loop;
  raise notice 'anon liberado em % funcao(oes)', n;
end $$;

-- 5. Confere o resultado aqui mesmo. Se sobrar qualquer admin_/patro_/
--    jantar_/checkin_ executavel por anon, a migration falha em vez de
--    deixar passar silenciosamente.
do $$
declare v_sobrou text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_sobrou
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'gestao'
    and has_function_privilege('anon', p.oid, 'EXECUTE')
    and (p.proname like 'admin%' or p.proname like 'patro%'
      or p.proname like 'jantar%' or p.proname like 'checkin%');

  if v_sobrou is not null then
    raise exception 'anon ainda executa: %', v_sobrou;
  end if;

  raise notice 'OK: nenhuma funcao sensivel executavel por anon';
end $$;

-- 6. E o espelho: tirar de PUBLIC nao pode ter derrubado quem esta
--    logado. Sem esta checagem, o portal quebraria inteiro e o sintoma
--    apareceria so na tela.
do $$
declare v_faltou text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_faltou
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'gestao'
    and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and (p.proname like 'admin%' or p.proname like 'patro%'
      or p.proname like 'jantar%' or p.proname like 'checkin%'
      or p.proname like 'part%');

  if v_faltou is not null then
    raise exception 'authenticated perdeu acesso a: %', v_faltou;
  end if;

  raise notice 'OK: authenticated mantem acesso as funcoes das telas';
end $$;
