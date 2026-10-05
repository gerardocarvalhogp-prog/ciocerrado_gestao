-- =====================================================================
-- Area do CIO: saude no rooming, visita ao lounge, presenca na mesa,
-- materiais, editar os proprios dados e indicar outra pessoa
-- · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM — mesmo padrao de 07 e 12.
-- Cria o proprio evento ('cob18').
--
-- COBRE (migrations sem teste ate 05/10/2026):
--
--   1. mobilidade/alergia/berco/observacoes no rooming, do titular e
--      de cada familiar (20260902090000)
--   2. visita ao lounge registrada pelo patrocinador (cracha) ou pelo
--      proprio CIO, sem duplicar; presenca na mesa redonda
--      (20260902110000)
--   3. materiais do CIO (catalogo/revista) e relatorio do Lounge
--      (20260909170000)
--   4. CIO edita os proprios dados (com historico) e indica outra
--      pessoa, que cai na fila de aprovacao (20260909180000)
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO
-- ---------------------------------------------------------------------
insert into eventos (slug,nome,status,data_inicio,data_fim)
values ('cob18','Cobertura 18','aberto','2027-08-12','2027-08-16');
select id as ev from eventos where slug='cob18' \gset

insert into admins (email,nome,role) values
  ('cob18-admin@teste.invalido','Admin Cob18','admin'),
  ('cob18-staff@teste.invalido','Staff Cob18','staff');
insert into admin_eventos (admin_id,evento_id)
select id, :'ev'::uuid from admins where email='cob18-staff@teste.invalido';

insert into cotas (evento_id,nome,ordem_prioridade,vagas_mesa_redonda) values (:'ev'::uuid,'Ouro Cob18',1,2);
select id as cota from cotas where evento_id=:'ev'::uuid \gset
insert into patrocinadores (evento_id,cota_id,empresa,status,lounge) values
  (:'ev'::uuid,:'cota'::uuid,'Patro Cob18 A','ativo','L-07'),
  (:'ev'::uuid,:'cota'::uuid,'Patro Cob18 B','ativo',null);
select id as pa from patrocinadores where empresa='Patro Cob18 A' and evento_id=:'ev'::uuid \gset
select id as pb from patrocinadores where empresa='Patro Cob18 B' and evento_id=:'ev'::uuid \gset
insert into usuarios_patrocinador (patrocinador_id,email,nome,telefone) values
  (:'pa'::uuid,'patro18a@teste.invalido','Contato A','61999990000'),
  (:'pb'::uuid,'patro18b@teste.invalido','Contato B',null);

insert into gestores (nome,email,empresa,cargo,telefone) values
  ('CIO Dezoito','cio18@teste.invalido','Industria Dezoito','CIO','61988887777')
on conflict (email_norm) do nothing;
insert into participantes (evento_id,gestor_id,status,origem,aprovado_em)
select :'ev'::uuid, id, 'aprovado','manual',now() from gestores where email='cio18@teste.invalido';
select pa.id as part, pa.gestor_id as gestor from participantes pa join gestores g on g.id=pa.gestor_id
 where g.email='cio18@teste.invalido' and pa.evento_id=:'ev'::uuid \gset
-- rooming so libera com contrato assinado
insert into contratos (participante_id,status,assinado_em) values (:'part'::uuid,'assinado',now());

-- quarto da cota de A, com um ocupante (cracha de patrocinador, nao CIO)
insert into reservas (evento_id,patrocinador_id,rotulo,tipo,origem,status)
values (:'ev'::uuid,:'pa'::uuid,'Quarto 1','duplo','cota','rascunho');
insert into ocupantes (reserva_id,nome,tipo)
select id,'Executivo A','adulto' from reservas where patrocinador_id=:'pa'::uuid;
select 'ocupante:' || o.id as cracha_patro from ocupantes o join reservas r on r.id=o.reserva_id
 where r.patrocinador_id=:'pa'::uuid \gset

insert into sessoes (evento_id,patrocinador_id,tipo,data,vagas)
values (:'ev'::uuid,:'pa'::uuid,'mesa_redonda','2027-08-13',2);
select id as sessao from sessoes where patrocinador_id=:'pa'::uuid \gset
insert into sessao_convidados (sessao_id,participante_id,origem) values (:'sessao'::uuid,:'part'::uuid,'patrocinador');
select id as convidado from sessao_convidados where sessao_id=:'sessao'::uuid \gset

\echo ''
\echo '#############################################'
\echo '# 1 · SAUDE NO ROOMING'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cio18@teste.invalido","role":"authenticated"}';
\echo '-- CIO salva: ele com mobilidade reduzida; filha de 2 anos com alergia e berco — deve PASSAR'
select part_salvar_rooming('cob18',
  '[{"nome":"Filha","tipo":"crianca","data_nascimento":"2025-03-01","tem_alergia":true,"alergia_detalhe":"amendoim","precisa_berco":true,"observacoes":"dorme cedo"}]'::jsonb,
  p_dificuldade_mobilidade => true, p_observacoes => 'cadeira de rodas') is not null as salvou_ok;
select bool_or(tipo='titular' and dificuldade_mobilidade and observacoes='cadeira de rodas' and not tem_alergia) as titular_ok,
       bool_or(tipo='crianca' and tem_alergia and alergia_detalhe='amendoim' and precisa_berco and observacoes='dorme cedo') as filha_ok
from part_listar_rooming('cob18');

\echo ''
\echo '#############################################'
\echo '# 2 · VISITA AO LOUNGE E PRESENCA NA MESA'
\echo '#############################################'
set request.jwt.claims = '{"email":"patro18a@teste.invalido","role":"authenticated"}';
\echo '-- A le o cracha do CIO — deve PASSAR'
select (r ->> 'ja_estava')::boolean = false and r ->> 'nome' ilike 'cio dezoito' as leu_cracha_ok
from patro_lounge_registrar(:'pa'::uuid, 'participante:' || :'part') r;
\echo '-- ler de novo nao duplica — deve PASSAR'
select (patro_lounge_registrar(:'pa'::uuid, 'participante:' || :'part') ->> 'ja_estava')::boolean as nao_duplica_ok;
savepoint s_cracha_patro;
\echo '-- cracha de executivo do patrocinador nao e de CIO — deve FALHAR'
select patro_lounge_registrar(:'pa'::uuid, :'cracha_patro');
rollback to s_cracha_patro;

set request.jwt.claims = '{"email":"cio18@teste.invalido","role":"authenticated"}';
\echo '-- CIO ve os patrocinadores do evento e se autodeclara no lounge de B — deve PASSAR'
select count(*) = 2 as ve_patrocinadores_ok from part_listar_patrocinadores('cob18');
select (part_lounge_registrar('cob18', :'pb'::uuid) ->> 'ja_estava')::boolean = false as autodeclarou_ok;
\echo '-- no lounge de A ele ja estava (registrado pelo patrocinador) — deve PASSAR'
select (part_lounge_registrar('cob18', :'pa'::uuid) ->> 'ja_estava')::boolean as ja_estava_ok;

-- id da visita lida pelo A, capturado como postgres (authenticated nao le tabela)
reset role;
reset request.jwt.claims;
select id as visita_a from lounge_visitas where patrocinador_id=:'pa'::uuid \gset
set role authenticated;
set request.jwt.claims = '{"email":"patro18b@teste.invalido","role":"authenticated"}';
\echo '-- B ve a visita com origem cio; filtrando por patrocinador, nada — deve PASSAR'
select count(*) = 1 and bool_and(origem='cio') as b_lista_ok from patro_lounge_listar(:'pb'::uuid);
select count(*) = 0 as filtro_origem_ok from patro_lounge_listar(:'pb'::uuid, 'patrocinador');
savepoint s_lounge_alheio;
\echo '-- B desfaz visita do lounge de A — deve FALHAR'
select patro_lounge_desfazer(:'visita_a'::uuid);
rollback to s_lounge_alheio;
savepoint s_presenca_alheia;
\echo '-- B marca presenca na mesa de A — deve FALHAR'
select patro_sessao_marcar_presenca(:'sessao'::uuid, :'convidado'::uuid);
rollback to s_presenca_alheia;

set request.jwt.claims = '{"email":"patro18a@teste.invalido","role":"authenticated"}';
\echo '-- A desfaz a propria leitura de cracha — deve PASSAR'
select patro_lounge_desfazer(:'visita_a'::uuid) ->> 'ok' = 'true' as desfez_ok;
select count(*) = 0 as sumiu_ok from patro_lounge_listar(:'pa'::uuid);
\echo '-- A marca o CIO presente na mesa redonda, e depois desmarca — deve PASSAR'
select patro_sessao_marcar_presenca(:'sessao'::uuid, :'convidado'::uuid) ->> 'ok' = 'true' as marcou_ok;
select presente and presente_em is not null as presente_ok from patro_meus_escolhidos(:'sessao'::uuid);
select patro_sessao_marcar_presenca(:'sessao'::uuid, :'convidado'::uuid, false) ->> 'ok' as desmarcou;
select not presente and presente_em is null as ausente_ok from patro_meus_escolhidos(:'sessao'::uuid);

\echo ''
\echo '#############################################'
\echo '# 3 · MATERIAIS DO CIO E RELATORIO DO LOUNGE'
\echo '#############################################'
set request.jwt.claims = '{"email":"cob18-staff@teste.invalido","role":"authenticated"}';
savepoint s_mat_staff;
\echo '-- staff cadastra material — so admin — deve FALHAR'
select admin_salvar_material_cio(p_tipo => 'revista', p_titulo => 'X', p_url => 'https://x.test');
rollback to s_mat_staff;

set request.jwt.claims = '{"email":"cob18-admin@teste.invalido","role":"authenticated"}';
savepoint s_mat_tipo;
\echo '-- tipo de material fora da lista — deve FALHAR'
select admin_salvar_material_cio(p_tipo => 'video', p_titulo => 'X', p_url => 'https://x.test');
rollback to s_mat_tipo;
savepoint s_mat_url;
\echo '-- material sem URL — deve FALHAR'
select admin_salvar_material_cio(p_tipo => 'revista', p_titulo => 'X', p_url => ' ');
rollback to s_mat_url;
\echo '-- admin cadastra uma revista ativa e um catalogo inativo — deve PASSAR'
select admin_salvar_material_cio(p_tipo => 'revista', p_titulo => 'Revista Cob18', p_url => 'https://rev18.test') ->> 'ok' = 'true'
   and admin_salvar_material_cio(p_tipo => 'catalogo', p_titulo => 'Catalogo Cob18', p_url => 'https://cat18.test', p_ativo => false) ->> 'ok' = 'true' as cadastrou_ok;

set request.jwt.claims = '{"email":"cio18@teste.invalido","role":"authenticated"}';
\echo '-- o CIO ve a revista ativa e NAO ve o catalogo inativo — deve PASSAR'
select bool_or(titulo='Revista Cob18') and not bool_or(titulo='Catalogo Cob18') as cio_ve_ativos_ok
from part_listar_materiais_cio('cob18');

set request.jwt.claims = '{"email":"patro18a@teste.invalido","role":"authenticated"}';
savepoint s_mat_nao_cio;
\echo '-- quem nao e CIO do evento nao lista materiais — deve FALHAR'
select * from part_listar_materiais_cio('cob18');
rollback to s_mat_nao_cio;

set request.jwt.claims = '{"email":"cob18-staff@teste.invalido","role":"authenticated"}';
\echo '-- relatorio do Lounge: so quem tem lounge (A), com o contato — deve PASSAR'
select count(*) = 1 and bool_and(lounge='L-07' and empresa='Patro Cob18 A' and contato_email='patro18a@teste.invalido') as rel_lounge_ok
from admin_rel_lounge('cob18');

\echo ''
\echo '#############################################'
\echo '# 4 · CIO EDITA OS PROPRIOS DADOS E INDICA OUTRA PESSOA'
\echo '#############################################'
set request.jwt.claims = '{"email":"cio18@teste.invalido","role":"authenticated"}';
savepoint s_dados_sem_nome;
\echo '-- salvar sem nome — deve FALHAR'
select part_salvar_meus_dados('cob18', '  ');
rollback to s_dados_sem_nome;
\echo '-- troca o cargo e a empresa — deve PASSAR'
select part_salvar_meus_dados('cob18', 'CIO Dezoito', '61988887777', 'CTO', 'Nova Empresa Dezoito', null, 'Goiania', 'GO')
       ->> 'ok' = 'true' as salvou_dados_ok;
select cargo ilike 'cto' and empresa ilike 'nova empresa dezoito' as dados_novos_ok from part_meus_dados('cob18');
reset role;
reset request.jwt.claims;
\echo '-- historico registra cargo e empresa como alterados pelo CIO — deve PASSAR'
select count(*) filter (where campo in ('cargo','empresa')) = 2 and bool_and(detectado_por='cio') as historico_ok
from gestores_historico where gestor_id=:'gestor'::uuid;

set role authenticated;
set request.jwt.claims = '{"email":"cio18@teste.invalido","role":"authenticated"}';
\echo '-- indica uma colega — deve PASSAR'
select part_indicar_pessoa('cob18', 'Colega Indicada', 'colega18@teste.invalido', null, 'Emp Colega', 'CIO') ->> 'ok' = 'true' as indicou_ok;
select count(*) = 1 and bool_and(status='pendente') as minhas_indicacoes_ok from part_minhas_indicacoes('cob18');
savepoint s_indica_dup;
\echo '-- indicar de novo quem ja esta inscrito — deve FALHAR'
select part_indicar_pessoa('cob18', 'Colega Indicada', 'COLEGA18@teste.invalido');
rollback to s_indica_dup;
savepoint s_indica_sem_email;
\echo '-- indicar sem e-mail — deve FALHAR'
select part_indicar_pessoa('cob18', 'Sem Email', '  ');
rollback to s_indica_sem_email;

reset role;
reset request.jwt.claims;
\echo '-- a indicada caiu na fila de aprovacao: pendente, origem indicacao, apontando pro CIO — deve PASSAR'
select pa.status = 'pendente' and pa.origem = 'indicacao' and pa.indicado_por_participante_id = :'part'::uuid as fila_ok
from participantes pa join gestores g on g.id=pa.gestor_id
where g.email='colega18@teste.invalido' and pa.evento_id=:'ev'::uuid;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
