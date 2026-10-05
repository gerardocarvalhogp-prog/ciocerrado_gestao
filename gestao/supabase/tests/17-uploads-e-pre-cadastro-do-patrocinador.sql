-- =====================================================================
-- Arquivos do patrocinador (logo/banner/...) e pre-cadastro de
-- patrocinador por link · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM — mesmo padrao de 07 e 12.
-- Cria o proprio evento ('cob17'). Escreve em storage.objects dentro
-- da transacao (so pra provar a policy do bucket) — o rollback desfaz.
--
-- COBRE (migrations sem teste ate 05/10/2026):
--
--   1. slots de arquivo pela cota: N logos + banner/arte/apresentacao/
--      video por boolean (20260902140000, 20260909150000)
--   2. reenviar a mesma (tipo, ordem) substitui e volta pra "enviado",
--      apagando a observacao da reprovacao anterior
--   3. revisao: so admin aprova/rejeita
--   4. pendencia "arquivos_enviados" fecha quando todos os slots tem
--      arquivo
--   5. policy do bucket patrocinador-uploads: cada patrocinador so
--      grava na propria pasta
--   6. pre-cadastro por link (20260909160000): anon abre e envia com o
--      token, so admin aprova/reprova, link vira so-leitura depois de
--      decidido; token sem pgcrypto (20260929090000)
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO
-- ---------------------------------------------------------------------
insert into eventos (slug,nome,status,data_inicio,data_fim,prazo_upload_padrao)
values ('cob17','Cobertura 17','aberto','2027-08-12','2027-08-16','2027-07-01');
select id as ev from eventos where slug='cob17' \gset

insert into prazos_evento (evento_id,etapa_chave,dias_atencao,dias_atrasado)
values (:'ev'::uuid,'arquivos_enviados',null,null);

insert into admins (email,nome,role) values
  ('cob17-admin@teste.invalido','Admin Cob17','admin'),
  ('cob17-staff@teste.invalido','Staff Cob17','staff');
insert into admin_eventos (admin_id,evento_id)
select id, :'ev'::uuid from admins where email='cob17-staff@teste.invalido';

-- cota pede 2 logos + banner; nao pede video
insert into cotas (evento_id,nome,ordem_prioridade,upload_logo_qtd,upload_banner)
values (:'ev'::uuid,'Ouro Cob17',1,2,true);
select id as cota from cotas where evento_id=:'ev'::uuid \gset
insert into patrocinadores (evento_id,cota_id,empresa,status) values
  (:'ev'::uuid,:'cota'::uuid,'Patro Cob17 A','ativo'),
  (:'ev'::uuid,:'cota'::uuid,'Patro Cob17 B','ativo');
select id as pa from patrocinadores where empresa='Patro Cob17 A' and evento_id=:'ev'::uuid \gset
select id as pb from patrocinadores where empresa='Patro Cob17 B' and evento_id=:'ev'::uuid \gset
insert into usuarios_patrocinador (patrocinador_id,email,nome) values
  (:'pa'::uuid,'patro17a@teste.invalido','Usuario A'),
  (:'pb'::uuid,'patro17b@teste.invalido','Usuario B');

\echo ''
\echo '#############################################'
\echo '# 1 · SLOTS DE ARQUIVO PELA COTA'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"patro17a@teste.invalido","role":"authenticated"}';
\echo '-- a cota pede logo 1, logo 2 e banner — nada de video; prazo vem do evento — deve PASSAR'
select array_agg(tipo || ordem order by tipo, ordem) = array['banner1','logo1','logo2']
       and bool_and(upload_id is null) and bool_and(prazo = '2027-07-01') as slots_ok
from patro_meus_uploads(:'pa'::uuid);

\echo '-- A sobe logo 1 (com largura/altura) e logo 2 — deve PASSAR'
select patro_registrar_upload(:'pa'::uuid,'logo',:'pa'||'/logo/1.pdf','logo1.pdf',1000,1,800,600) ->> 'id' as up_logo1 \gset
select patro_registrar_upload(:'pa'::uuid,'logo',:'pa'||'/logo/2.pdf','logo2.pdf',1000,2) ->> 'ok' = 'true' as logo2_ok;
select largura = 800 and altura = 600 and status = 'enviado' as logo1_ok
from patro_meus_uploads(:'pa'::uuid) where tipo='logo' and ordem=1;

savepoint s_tipo_inv;
\echo '-- tipo fora da lista — deve FALHAR'
select patro_registrar_upload(:'pa'::uuid,'planilha','x/y.xlsx','y.xlsx');
rollback to s_tipo_inv;
savepoint s_ordem_inv;
\echo '-- ordem zero — deve FALHAR'
select patro_registrar_upload(:'pa'::uuid,'logo','x/y.pdf','y.pdf',1,0);
rollback to s_ordem_inv;

savepoint s_achado_video;
\echo '-- ACHADO (05/10/2026): a cota NAO pede video, mas patro_registrar_upload aceita'
\echo '-- video (e logo de ordem 3, alem das 2 da cota). So a tela deixa de oferecer o'
\echo '-- slot — o banco nao confere a cota. Pelo CLAUDE.md, regra fica na funcao.'
select patro_registrar_upload(:'pa'::uuid,'video',:'pa'||'/video/1.mp4','v.mp4') ->> 'ok' as video_fora_da_cota_aceito,
       patro_registrar_upload(:'pa'::uuid,'logo',:'pa'||'/logo/3.pdf','l3.pdf',1,3) ->> 'ok' as logo_3_aceito;
rollback to s_achado_video;

set request.jwt.claims = '{"email":"patro17b@teste.invalido","role":"authenticated"}';
savepoint s_alheio;
\echo '-- B registra arquivo no patrocinador de A — deve FALHAR'
select patro_registrar_upload(:'pa'::uuid,'banner','x/b.pdf','b.pdf');
rollback to s_alheio;
savepoint s_alheio_rem;
\echo '-- B remove arquivo de A — deve FALHAR'
select patro_remover_upload(:'up_logo1'::uuid);
rollback to s_alheio_rem;

\echo ''
\echo '#############################################'
\echo '# 2 · REVISAO: SO ADMIN'
\echo '#############################################'
set request.jwt.claims = '{"email":"cob17-staff@teste.invalido","role":"authenticated"}';
\echo '-- staff do evento ve os arquivos — deve PASSAR'
select count(*) = 2 as staff_ve_ok from admin_listar_uploads('cob17');
savepoint s_rev_staff;
\echo '-- staff (nao admin) reprova — deve FALHAR'
select admin_revisar_upload(:'up_logo1'::uuid,'rejeitado','borrado');
rollback to s_rev_staff;

set request.jwt.claims = '{"email":"cob17-admin@teste.invalido","role":"authenticated"}';
savepoint s_rev_inv;
\echo '-- status de revisao fora da lista — deve FALHAR'
select admin_revisar_upload(:'up_logo1'::uuid,'enviado');
rollback to s_rev_inv;
\echo '-- admin reprova o logo 1 com motivo — deve PASSAR'
select admin_revisar_upload(:'up_logo1'::uuid,'rejeitado','Logo borrado') ->> 'ok' = 'true' as reprovou_ok;

set request.jwt.claims = '{"email":"patro17a@teste.invalido","role":"authenticated"}';
select status = 'rejeitado' and observacao_admin = 'Logo borrado' as patro_ve_motivo_ok
from patro_meus_uploads(:'pa'::uuid) where tipo='logo' and ordem=1;
\echo '-- reenviar o logo 1 substitui a MESMA linha, volta pra enviado e limpa o motivo — deve PASSAR'
select patro_registrar_upload(:'pa'::uuid,'logo',:'pa'||'/logo/1-v2.pdf','logo1-v2.pdf',1,1) ->> 'id' = :'up_logo1' as mesma_linha_ok;
select status = 'enviado' and observacao_admin is null and nome_arquivo = 'logo1-v2.pdf' and largura is null as reenvio_ok
from patro_meus_uploads(:'pa'::uuid) where tipo='logo' and ordem=1;

\echo ''
\echo '#############################################'
\echo '# 3 · PENDENCIA "ARQUIVOS ENVIADOS"'
\echo '#############################################'
reset role;
reset request.jwt.claims;
\echo '-- 2 logos mas sem banner: pendente — deve PASSAR'
select status = 'pendente' and vencimento = '2027-07-01' as pendente_ok
from v_pendencias where sujeito_id=:'pa'::uuid and etapa_chave='arquivos_enviados';
set role authenticated;
set request.jwt.claims = '{"email":"patro17a@teste.invalido","role":"authenticated"}';
select patro_registrar_upload(:'pa'::uuid,'banner',:'pa'||'/banner/1.pdf','banner.pdf') ->> 'ok' as subiu_banner;
reset role;
reset request.jwt.claims;
\echo '-- com o banner, todos os slots tem arquivo: concluida — deve PASSAR'
select status = 'concluida' as concluida_ok
from v_pendencias where sujeito_id=:'pa'::uuid and etapa_chave='arquivos_enviados';

update patrocinador_uploads set status='rejeitado' where patrocinador_id=:'pa'::uuid and tipo='banner';
\echo '-- ACHADO (05/10/2026): banner REJEITADO pelo admin continua contando como'
\echo '-- "arquivo enviado" — a pendencia segue concluida e ninguem e cobrado de'
\echo '-- mandar outro. v_pendencias_fatos conta a linha, nao o status dela.'
select status as status_da_pendencia_com_banner_rejeitado
from v_pendencias where sujeito_id=:'pa'::uuid and etapa_chave='arquivos_enviados';

\echo ''
\echo '#############################################'
\echo '# 4 · POLICY DO BUCKET: SO A PROPRIA PASTA'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"patro17a@teste.invalido","role":"authenticated"}';
\echo '-- A grava na pasta dele — deve PASSAR'
insert into storage.objects (bucket_id, name) values ('patrocinador-uploads', :'pa'||'/logo/teste17.pdf');
select true as gravou_na_propria_pasta_ok;
savepoint s_bucket_alheio;
\echo '-- A grava na pasta de B — deve FALHAR'
insert into storage.objects (bucket_id, name) values ('patrocinador-uploads', :'pb'||'/logo/intruso.pdf');
rollback to s_bucket_alheio;

\echo ''
\echo '#############################################'
\echo '# 5 · PRE-CADASTRO POR LINK'
\echo '#############################################'
set request.jwt.claims = '{"email":"cob17-staff@teste.invalido","role":"authenticated"}';
savepoint s_conv_staff;
\echo '-- staff gera convite — so admin — deve FALHAR'
select admin_criar_convite_pre_cadastro('cob17');
rollback to s_conv_staff;

set request.jwt.claims = '{"email":"cob17-admin@teste.invalido","role":"authenticated"}';
\echo '-- admin gera convite: token de 32 hex, sem pgcrypto — deve PASSAR'
select c ->> 'token' as token, c ->> 'id' as pc_id
from admin_criar_convite_pre_cadastro('cob17') c \gset
select :'token' ~ '^[0-9a-f]{32}$' as token_ok;
select c ->> 'token' as token2, c ->> 'id' as pc2_id
from admin_criar_convite_pre_cadastro('cob17') c \gset

-- o prospect nao tem login
set role anon;
set request.jwt.claims = '{"role":"anon"}';
\echo '-- anon abre o link: status aberto, nome do evento — deve PASSAR'
select (r ->> 'ok')::boolean and r ->> 'status' = 'aberto' and r ->> 'evento_nome' = 'Cobertura 17' as abriu_ok
from pre_cadastro_obter(:'token') r;
\echo '-- token que nao existe: ok=false, sem erro — deve PASSAR'
select pre_cadastro_obter('naoexiste') ->> 'motivo' = 'nao_encontrado' as inexistente_ok;
savepoint s_sem_contato;
\echo '-- envio sem e-mail de contato — deve FALHAR'
select pre_cadastro_enviar(:'token', 'Prospect Cob17', p_nome_contato => 'Fulana');
rollback to s_sem_contato;
savepoint s_natureza;
\echo '-- natureza fora da lista — deve FALHAR'
select pre_cadastro_enviar(:'token', 'Prospect Cob17', p_natureza => 'ong', p_nome_contato => 'Fulana', p_email_contato => 'f@p.test');
rollback to s_natureza;
\echo '-- envio valido (e-mail vira minusculo) — deve PASSAR'
select pre_cadastro_enviar(:'token', ' Prospect Cob17 ', p_segmento => 'Varejo', p_natureza => 'privada',
                           p_nome_contato => 'Fulana', p_email_contato => ' Fulana@Prospect.TEST ') ->> 'ok' = 'true' as enviou_ok;
\echo '-- reenviar pra corrigir, enquanto nao decidido — deve PASSAR'
select pre_cadastro_enviar(:'token', 'Prospect Cob17', p_segmento => 'Varejo', p_natureza => 'privada',
                           p_nome_contato => 'Fulana', p_email_contato => 'fulana@prospect.test',
                           p_cidade => 'Goiania') ->> 'ok' = 'true' as corrigiu_ok;
savepoint s_anon_admin;
\echo '-- anon tenta aprovar — deve FALHAR'
select admin_aprovar_pre_cadastro(:'pc_id'::uuid);
rollback to s_anon_admin;

set role authenticated;
set request.jwt.claims = '{"email":"cob17-staff@teste.invalido","role":"authenticated"}';
\echo '-- staff do evento ve o enviado na fila — deve PASSAR'
select empresa = 'Prospect Cob17' and email_contato = 'fulana@prospect.test' and cidade = 'Goiania' as fila_ok
from admin_listar_pre_cadastros('cob17','enviado');
savepoint s_aprov_staff;
\echo '-- staff (nao admin) aprova — deve FALHAR'
select admin_aprovar_pre_cadastro(:'pc_id'::uuid);
rollback to s_aprov_staff;

set request.jwt.claims = '{"email":"cob17-admin@teste.invalido","role":"authenticated"}';
savepoint s_aprov_aberto;
\echo '-- aprovar convite ainda "aberto" (ninguem preencheu) — deve FALHAR'
select admin_aprovar_pre_cadastro(:'pc2_id'::uuid);
rollback to s_aprov_aberto;
\echo '-- admin aprova: vira patrocinador do evento — deve PASSAR'
select admin_aprovar_pre_cadastro(:'pc_id'::uuid) ->> 'patrocinador_id' is not null as aprovou_ok;
select count(*) = 1 as virou_patrocinador_ok from admin_listar_patrocinadores('cob17') where empresa ilike 'prospect cob17';

savepoint s_reprov_sem_motivo;
\echo '-- reprovar sem motivo — deve FALHAR'
select admin_reprovar_pre_cadastro(:'pc2_id'::uuid, '  ');
rollback to s_reprov_sem_motivo;
set role anon;
set request.jwt.claims = '{"role":"anon"}';
select pre_cadastro_enviar(:'token2', 'Outro Prospect', p_nome_contato => 'Beltrano', p_email_contato => 'b@p.test') ->> 'ok' as segundo_enviou;
set role authenticated;
set request.jwt.claims = '{"email":"cob17-admin@teste.invalido","role":"authenticated"}';
\echo '-- reprova o segundo com motivo — deve PASSAR'
select admin_reprovar_pre_cadastro(:'pc2_id'::uuid, 'Fora do perfil') ->> 'ok' = 'true' as reprovou_ok;

set role anon;
set request.jwt.claims = '{"role":"anon"}';
\echo '-- o prospect reprovado ve o motivo — deve PASSAR'
select r ->> 'status' = 'reprovado' and r ->> 'motivo_reprovacao' = 'Fora do perfil' as ve_motivo_ok
from pre_cadastro_obter(:'token2') r;
savepoint s_reenvio_decidido;
\echo '-- link decidido vira so-leitura: reenviar — deve FALHAR'
select pre_cadastro_enviar(:'token2', 'Outro Prospect', p_nome_contato => 'Beltrano', p_email_contato => 'b@p.test');
rollback to s_reenvio_decidido;

set role authenticated;
set request.jwt.claims = '{"email":"cob17-admin@teste.invalido","role":"authenticated"}';
savepoint s_remover_decidido;
\echo '-- remover convite ja decidido — deve FALHAR'
select admin_remover_convite_pre_cadastro(:'pc_id'::uuid);
rollback to s_remover_decidido;

reset role;
reset request.jwt.claims;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
