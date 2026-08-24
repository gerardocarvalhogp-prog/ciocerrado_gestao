-- =====================================================================
-- Bateria de verificacao pos-migration  ·  gestao CIO Cerrado
--
-- Roda contra o banco LOCAL depois de supabase start / db reset.
-- Cobre o que a analise estatica nao alcanca.
-- =====================================================================

\echo '=== 1. O schema existe e tem objetos ==='
select
  (select count(*) from information_schema.tables  where table_schema='gestao') as tabelas,
  (select count(*) from information_schema.views   where table_schema='gestao') as views,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='gestao') as funcoes;

\echo ''
\echo '=== 2. As 92 RPCs que as telas chamam existem? ==='
with esperadas(nome) as (values
 ('listar_cotas'),('patro_meu_painel'),('patro_manual'),('patro_listar_quartos'),
 ('patro_disponibilidade'),('patro_listar_ocupantes'),('patro_comprar_quarto'),
 ('patro_cancelar_quarto_extra'),('patro_salvar_quarto'),('patro_minhas_sessoes'),
 ('patro_minha_vez'),('patro_convidados_disponiveis'),('patro_escolher_convidados'),
 ('patro_passar_a_vez'),('patro_indicar_cio'),('patro_listar_indicacoes'),
 ('part_autocadastro'),('part_meu_status'),('part_listar_rooming'),
 ('part_previa_fatura'),('part_salvar_rooming'),
 ('checkin_resumo'),('checkin_listar'),('checkin_registrar'),('checkin_cadastrar'),
 ('checkin_desfazer'),
 ('admin_listar_eventos'),('admin_salvar_evento'),('admin_listar_cotas'),
 ('admin_salvar_cota'),('admin_remover_cota'),('admin_definir_patrocinadores_cota'),
 ('admin_listar_patrocinadores'),('admin_salvar_patrocinador'),
 ('admin_enriquecer_patrocinador'),('admin_remover_patrocinador'),
 ('admin_listar_usuarios_patro'),('admin_salvar_usuario_patro'),
 ('admin_remover_usuario_patro'),('admin_resumo_quartos'),
 ('admin_criar_faixa_quartos'),('admin_gerar_quartos_todos'),
 ('admin_listar_pendentes'),('admin_aprovar_participante'),
 ('admin_listar_indicacoes'),('admin_converter_indicacao'),
 ('admin_importar_gestores'),('admin_listar_sugestoes'),('admin_aplicar_sugestao'),
 ('admin_listar_alocacao'),('admin_quartos_livres'),('admin_alocar_quarto'),
 ('admin_etiquetas'),('admin_listar_sessoes'),('admin_convidados_sessao'),
 ('admin_match_jantar'),('admin_adicionar_convidado_sessao'),
 ('admin_remover_convidado_sessao'),('admin_convidado_avulso'),
 ('admin_mailing_sessao'),('admin_listar_precos'),('admin_salvar_preco'),
 ('admin_remover_preco'),('admin_listar_equipe'),('admin_salvar_membro'),
 ('admin_remover_membro'),('admin_rel_painel'),('admin_rel_mailing'),
 ('admin_rel_pesquisa'),('admin_rel_checkins_resumo'),('admin_rel_checkins_detalhe'),
 ('admin_pesquisa_resumo'),('admin_importar_pesquisa'),('admin_pesquisa_areas'),
 ('admin_pesquisa_por_area'),('admin_listar_rodadas'),('admin_empresas_da_rodada'),
 ('admin_localidades_base'),('admin_prospeccao_base'),('admin_salvar_prospeccao'),
 ('jantar_listar'),('jantar_obter'),('jantar_salvar'),('jantar_remover'),
 ('jantar_convidados_listar'),('jantar_marcar_convidado'),
 ('jantar_remover_convidado'),('jantar_avulso'),('jantar_salvar_selecao'),
 ('jantar_base'),('jantar_estatisticas_gestores'),('jantar_empresas_sem_convite')
)
select e.nome as rpc_ausente
from esperadas e
where not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='gestao' and p.proname = e.nome);

\echo '(vazio acima = todas presentes)'

\echo ''
\echo '=== 3. Funcao definida mais de uma vez com assinaturas diferentes ==='
-- sobrecarga acidental: a tela chama por nome + parametros nomeados,
-- e duas versoes fazem o PostgREST recusar com "could not choose"
select p.proname, count(*) as versoes,
       string_agg(pg_get_function_identity_arguments(p.oid), '  |  ') as assinaturas
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='gestao'
group by p.proname having count(*) > 1;

\echo '(vazio acima = sem sobrecarga)'

\echo ''
\echo '=== 4. Seed aplicou? ==='
select
  (select count(*) from gestao.eventos)  as eventos,
  (select count(*) from gestao.cotas)    as cotas,
  (select count(*) from gestao.precos)   as precos,
  (select count(*) from gestao.admins where role='admin' and ativo) as admins;

\echo ''
\echo '=== 5. anon nao pode executar funcao sensivel ==='
select p.proname
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='gestao'
  and has_function_privilege('anon', p.oid, 'EXECUTE')
  and (p.proname like 'admin%' or p.proname like 'patro%' or p.proname like 'jantar%')
order by 1;

\echo '(vazio acima = anon barrado; part_autocadastro fica liberada de proposito)'

\echo ''
\echo '=== 6. RLS ligada em todas as tabelas do schema ==='
select c.relname as tabela_sem_rls
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='gestao' and c.relkind='r' and not c.relrowsecurity
order by 1;

\echo '(vazio acima = RLS ligada em tudo)'

\echo ''
\echo '=== 7. O sistema de massagem continua intacto ==='
-- So faz sentido no projeto HOSPEDADO: o schema public de la e o do
-- agendamento de massagem, em producao. No banco local ele nasce vazio,
-- entao a ausencia da funcao aqui e o esperado, nao um alarme.
do $$
declare v text;
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                 where n.nspname='public' and p.proname='norm_doc') then
    raise notice 'public.norm_doc nao existe - banco local, nada a verificar';
    return;
  end if;
  execute $q$select public.norm_doc('048.742.986-99')$q$ into v;
  if v = '04874298699' then
    raise notice 'OK: public.norm_doc intacta';
  else
    raise warning 'public.norm_doc devolveu "%" - ESPERADO 04874298699. O sistema de massagem depende dela.', v;
  end if;
end $$;

\echo ''
\echo '=== 8. Compilacao real do corpo de cada funcao plpgsql ==='
-- CREATE FUNCTION so valida sintaxe. plpgsql_check_function abre o
-- corpo e resolve tabelas, colunas e chamadas - e o que pega o
-- "column reference is ambiguous" e coluna inexistente em SELECT.
-- Se a extensao nao existir na imagem, este bloco e ignorado.
do $$
declare r record; n int := 0; msg text;
begin
  if not exists (select 1 from pg_available_extensions where name='plpgsql_check') then
    raise notice 'plpgsql_check indisponivel nesta imagem - pulando';
    return;
  end if;
  create extension if not exists plpgsql_check;
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n2 on n2.oid=p.pronamespace
    join pg_language l on l.oid=p.prolang
    where n2.nspname='gestao' and l.lanname='plpgsql'
  loop
    begin
      for msg in select * from plpgsql_check_function(r.sig) loop
        raise notice '% -> %', r.sig, msg;
        n := n + 1;
      end loop;
    exception when others then
      raise notice '% -> falhou ao checar: %', r.sig, sqlerrm;
    end;
  end loop;
  raise notice 'plpgsql_check: % apontamento(s)', n;
end $$;
