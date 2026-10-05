-- =====================================================================
-- Grupos de WhatsApp por jantar: telefone E.164, aviso de confirmacao,
-- importacao do Sympla, pipeline do grupo (organizador -> daemon ->
-- convites) · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM — mesmo padrao de 07 e 12.
-- Nada sai de verdade: o teste so olha a fila `notificacoes` (o envio
-- e outra peca, a Edge Function), e o rollback desfaz a fila tambem.
-- Jantar e global; tudo aqui tem "Cob20" no nome.
--
-- COBRE (20260912090000, sem teste ate 05/10/2026):
--
--   1. norm_telefone_e164 e gestores.telefone_e164
--   2. aviso de confirmacao enfileirado so na TRANSICAO pra
--      'confirmado' (marcar na mao ou importar do Sympla), nunca de novo
--   3. jantar_importar_convidados_sympla: cria, atualiza, rebaixa
--      cancelado, nao mexe em quem ja compareceu, aponta erro por linha
--   4. pipeline: solicitar (admin, >=1 confirmado, sem duplicar) ->
--      daemon com chave service_role (pendentes, contatos, avancar) ->
--      convites com o link so depois de 'criado'
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO
-- ---------------------------------------------------------------------
insert into admins (email,nome,role) values
  ('cob20-admin@teste.invalido','Admin Cob20','admin'),
  ('cob20-staff@teste.invalido','Staff Cob20','staff');

insert into gestores (nome,email,empresa,cargo,telefone) values
  ('Ana Cob20','ana20@teste.invalido','Emp Ana','CIO','(62) 99999-1234'),
  ('Bruno Cob20','bruno20@teste.invalido','Emp Bruno','CIO',null),
  ('Carla Cob20','carla20@teste.invalido','Emp Carla','CIO','61 98888-0000')
on conflict (email_norm) do nothing;
select id as g_ana   from gestores where email='ana20@teste.invalido' \gset
select id as g_bruno from gestores where email='bruno20@teste.invalido' \gset
select id as g_carla from gestores where email='carla20@teste.invalido' \gset

insert into jantares (patrocinador_nome,data,capacidade) values ('Patro Cob20', current_date + 7, 10);
select id as jantar from jantares where patrocinador_nome='Patro Cob20' \gset
insert into jantar_convidados (jantar_id,gestor_id,origem,status) values
  (:'jantar'::uuid,:'g_ana'::uuid,'manual','convidado'),
  (:'jantar'::uuid,:'g_bruno'::uuid,'manual','convidado');
select id as jc_ana   from jantar_convidados where jantar_id=:'jantar'::uuid and gestor_id=:'g_ana'::uuid \gset
select id as jc_bruno from jantar_convidados where jantar_id=:'jantar'::uuid and gestor_id=:'g_bruno'::uuid \gset

\echo ''
\echo '#############################################'
\echo '# 1 · TELEFONE EM E.164'
\echo '#############################################'
\echo '-- celular com 9, com mascara, com +55, ja com 55; lixo vira nulo — deve PASSAR'
select norm_telefone_e164('(62) 99999-1234')   = '5562999991234'
   and norm_telefone_e164('+55 62 99999-1234') = '5562999991234'
   and norm_telefone_e164('556299991234')      = '556299991234'
   and norm_telefone_e164('62 9999-1234')      = '5562999991234'
   and norm_telefone_e164('12345') is null
   and norm_telefone_e164(null) is null as e164_ok;
select telefone_e164 = '5562999991234' as coluna_gerada_ok from gestores where id=:'g_ana'::uuid;

\echo '-- ACHADO (05/10/2026): numero FIXO com DDD (10 digitos, comeca com 2-5) tambem'
\echo '-- ganha o 9 na frente, virando um celular que nao existe. O comentario da'
\echo '-- migration diz "fixo continua com 8" e "numero que nao bate vira null em'
\echo '-- vez de adivinhar — E.164 errado manda mensagem pro numero errado".'
select norm_telefone_e164('(62) 3222-1111') as fixo_vira;

\echo ''
\echo '#############################################'
\echo '# 2 · AVISO DE CONFIRMACAO SO NA TRANSICAO'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cob20-staff@teste.invalido","role":"authenticated"}';
\echo '-- staff confirma Ana e Bruno — deve PASSAR'
select jantar_marcar_convidado(:'jc_ana'::uuid,'confirmado') ->> 'ok' = 'true'
   and jantar_marcar_convidado(:'jc_bruno'::uuid,'confirmado') ->> 'ok' = 'true' as confirmou_ok;
\echo '-- reconfirmar a Ana nao manda de novo — deve PASSAR'
select jantar_marcar_convidado(:'jc_ana'::uuid,'confirmado') ->> 'ok' = 'true' as reconfirmou_ok;
reset role;
reset request.jwt.claims;
\echo '-- fila: 1 aviso pra Ana (com telefone, template, parametros); nada pro Bruno (sem telefone) — deve PASSAR'
select count(*) = 1 and bool_and(destinatario='5562999991234' and canal='whatsapp'
       and template_nome='cio_cerrado_confirmacao_jantar' and template_params ->> 0 = 'ANA COB20') as aviso_ana_ok
from notificacoes where sujeito_id=:'jc_ana'::uuid and tipo='jantar_confirmacao_inscricao';
select count(*) = 0 as nada_pro_bruno_ok from notificacoes where sujeito_id=:'jc_bruno'::uuid;

\echo ''
\echo '#############################################'
\echo '# 3 · IMPORTACAO DO SYMPLA'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cob20-staff@teste.invalido","role":"authenticated"}';
savepoint s_import_staff;
\echo '-- staff importa — so admin — deve FALHAR'
select jantar_importar_convidados_sympla(:'jantar'::uuid, '[]'::jsonb);
rollback to s_import_staff;

set request.jwt.claims = '{"email":"cob20-admin@teste.invalido","role":"authenticated"}';
\echo '-- 6 linhas: Carla nova (e-mail corporativo vence), Ana repetida, Bruno cancelou,'
\echo '-- sem e-mail, e-mail invalido, pagamento pendente — deve PASSAR'
select (r ->> 'criados')::int = 1 and (r ->> 'atualizados')::int = 1 and (r ->> 'recusados')::int = 1
   and (r ->> 'erros')::int = 3 as importou_ok
from jantar_importar_convidados_sympla(:'jantar'::uuid, '[
  {"nome":"Carla","email":"pessoal@x.test","email_corporativo":" CARLA20@teste.invalido ","estado_pagamento":"Aprovado","sympla_id":"S1"},
  {"nome":"Ana","email":"ana20@teste.invalido","estado_pagamento":"aprovado"},
  {"nome":"Bruno","email":"bruno20@teste.invalido","estado_pagamento":"Cancelado"},
  {"nome":"Sem Email","estado_pagamento":"aprovado"},
  {"nome":"Ruim","email":"nao-e-email","estado_pagamento":"aprovado"},
  {"nome":"Pendente","email":"pend20@teste.invalido","estado_pagamento":"pendente"}
]'::jsonb) r;
reset role;
reset request.jwt.claims;
\echo '-- Carla entrou confirmada (origem sympla); Ana (ja confirmada) NAO ganhou segundo aviso; Bruno virou recusado — deve PASSAR'
select status='confirmado' and origem='sympla' and sympla_id='S1' as carla_ok
from jantar_convidados where jantar_id=:'jantar'::uuid and gestor_id=:'g_carla'::uuid;
select count(*) = 1 as ana_um_aviso_so_ok from notificacoes where sujeito_id=:'jc_ana'::uuid;

\echo '-- ACHADO (05/10/2026): Carla e NOVA no jantar, entrou confirmada pela importacao'
\echo '-- e tem celular valido — mas o aviso de confirmacao NAO foi enfileirado. Na'
\echo '-- funcao, "select exists(...), status into v_existia ..." nao devolve linha'
\echo '-- quando o convidado ainda nao existe, v_existia fica NULL e'
\echo '-- "if not (v_existia and ...)" nao entra. Todo convidado novo vindo do Sympla'
\echo '-- (o caminho automatico do integracao.py --jantares) fica sem o aviso.'
select count(*) as avisos_da_carla_esperado_1
from notificacoes n join jantar_convidados jc on jc.id=n.sujeito_id
where jc.jantar_id=:'jantar'::uuid and jc.gestor_id=:'g_carla'::uuid and n.tipo='jantar_confirmacao_inscricao';

\echo '-- Bruno (cancelou no Sympla) virou recusado — deve PASSAR'
select status = 'recusado' as bruno_recusado_ok from jantar_convidados where id=:'jc_bruno'::uuid;
\echo '-- ACHADO (05/10/2026): a linha com pagamento "pendente" foi recusada (conta em'
\echo '-- erros, nao entra no jantar) mas o gestor dela JA foi criado na base — a'
\echo '-- funcao cria/atualiza o gestor antes de olhar o estado do pagamento. Vale'
\echo '-- tambem pra linha "cancelado" de quem nao existia. Efeito: cadastro novo na'
\echo '-- base de gestores a partir de inscricao nao concluida.'
select exists (select 1 from gestores where email='pend20@teste.invalido') as gestor_de_linha_recusada_criado;

update jantar_convidados set status='compareceu' where id=:'jc_ana'::uuid;
set role authenticated;
set request.jwt.claims = '{"email":"cob20-admin@teste.invalido","role":"authenticated"}';
\echo '-- reimportar quem ja COMPARECEU como cancelado nao rebaixa — deve PASSAR'
select (jantar_importar_convidados_sympla(:'jantar'::uuid, '[{"nome":"Ana","email":"ana20@teste.invalido","estado_pagamento":"cancelado"}]'::jsonb) ->> 'recusados')::int = 0 as nao_rebaixou_ok;
reset role;
reset request.jwt.claims;
select status = 'compareceu' as ana_continua_ok from jantar_convidados where id=:'jc_ana'::uuid;
update jantar_convidados set status='confirmado' where id=:'jc_ana'::uuid;

\echo ''
\echo '#############################################'
\echo '# 4 · PIPELINE DO GRUPO'
\echo '#############################################'
insert into jantares (patrocinador_nome,data) values ('Patro Cob20 Vazio', current_date + 7);
select id as jantar_vazio from jantares where patrocinador_nome='Patro Cob20 Vazio' \gset

set role authenticated;
set request.jwt.claims = '{"email":"cob20-admin@teste.invalido","role":"authenticated"}';
savepoint s_sem_confirmado;
\echo '-- jantar sem confirmado nenhum — deve FALHAR'
select jantar_grupo_solicitar(:'jantar_vazio'::uuid);
rollback to s_sem_confirmado;

set request.jwt.claims = '{"email":"cob20-staff@teste.invalido","role":"authenticated"}';
savepoint s_achado_obter;
\echo '-- ACHADO (05/10/2026): jantar_grupo_obter (a que jantares.html chama pra mostrar'
\echo '-- o estado do grupo) estoura com "column reference status is ambiguous" pra'
\echo '-- QUALQUER jantar: o retorno declara uma coluna "status" e o subselect que'
\echo '-- conta confirmados usa "status" sem qualificar. A tela nunca carrega.'
select * from jantar_grupo_obter(:'jantar'::uuid);
rollback to s_achado_obter;
savepoint s_solicitar_staff;
\echo '-- staff solicita grupo (efeito externo real) — so admin — deve FALHAR'
select jantar_grupo_solicitar(:'jantar'::uuid);
rollback to s_solicitar_staff;

set request.jwt.claims = '{"email":"cob20-admin@teste.invalido","role":"authenticated"}';
\echo '-- admin solicita — deve PASSAR'
select (jantar_grupo_solicitar(:'jantar'::uuid) ->> 'confirmados')::int = 2 as solicitou_ok;
savepoint s_em_andamento;
\echo '-- solicitar de novo com a criacao em andamento — deve FALHAR'
select jantar_grupo_solicitar(:'jantar'::uuid);
rollback to s_em_andamento;
savepoint s_convite_cedo;
\echo '-- enfileirar convites antes do grupo existir — deve FALHAR'
select jantar_grupo_enfileirar_convites(:'jantar'::uuid);
rollback to s_convite_cedo;

-- o daemon fala com a chave service_role (JWT sem e-mail)
set role service_role;
set request.jwt.claims = '{"role":"service_role"}';
\echo '-- daemon (service_role) ve o pedido pendente e a lista de contatos — deve PASSAR'
select count(*) = 1 as pendente_ok from jantar_grupos_pendentes() where jantar_id=:'jantar'::uuid;
select count(*) = 2 and bool_and(not ja_sincronizado) as contatos_ok from jantar_grupo_convidados_para_sincronizar(:'jantar'::uuid);
select jantar_convidado_marcar_contato_sincronizado(:'jc_ana'::uuid, 'people/c123');
select count(*) filter (where ja_sincronizado) = 1 as sincronizou_ok from jantar_grupo_convidados_para_sincronizar(:'jantar'::uuid);
savepoint s_status_daemon;
\echo '-- daemon manda status fora da lista — deve FALHAR'
select jantar_grupo_daemon_avancar(:'jantar'::uuid, 'pronto');
rollback to s_status_daemon;
select jantar_grupo_daemon_avancar(:'jantar'::uuid, 'criado', '123-456@g.us', 'https://chat.whatsapp.test/abc');
select whatsapp_log_registrar(:'jantar'::uuid, 'grupo_criado', '{"jid":"123-456@g.us"}'::jsonb);
\echo '-- grupo criado: convites com o link pros 2 confirmados com telefone (Ana e Carla) — deve PASSAR'
select jantar_grupo_enfileirar_convites(:'jantar'::uuid) = 2 as convites_ok;
\echo '-- e o pedido saiu da lista de pendentes — deve PASSAR'
select not exists (select 1 from jantar_grupos_pendentes() where jantar_id=:'jantar'::uuid) as saiu_pendentes_ok;

-- jantar_grupo_obter esta quebrada (ACHADO acima): confere direto na tabela
reset role;
reset request.jwt.claims;
\echo '-- grupo gravado como criado, com link e data — deve PASSAR'
select status = 'criado' and invite_link = 'https://chat.whatsapp.test/abc' and criado_em is not null
       and whatsapp_group_jid = '123-456@g.us' as grupo_ok
from jantar_grupos where jantar_id=:'jantar'::uuid;
set role authenticated;
set request.jwt.claims = '{"email":"cob20-admin@teste.invalido","role":"authenticated"}';
savepoint s_ja_criado;
\echo '-- solicitar de novo depois de criado — deve FALHAR'
select jantar_grupo_solicitar(:'jantar'::uuid);
rollback to s_ja_criado;

set request.jwt.claims = '{"email":"cob20-staff@teste.invalido","role":"authenticated"}';
savepoint s_daemon_staff;
\echo '-- staff logado chama funcao do daemon — deve FALHAR'
select jantar_grupos_pendentes();
rollback to s_daemon_staff;

reset role;
reset request.jwt.claims;
\echo '-- fila de convites e log — deve PASSAR'
select count(*) = 2 and bool_and(template_params ->> 1 = 'https://chat.whatsapp.test/abc') as fila_convites_ok
from notificacoes n join jantar_convidados jc on jc.id = n.sujeito_id
where jc.jantar_id=:'jantar'::uuid and n.tipo='jantar_link_grupo';
select array_agg(acao order by created_at) = array['solicitado','grupo_criado'] as log_ok
from whatsapp_operacional_log where jantar_id=:'jantar'::uuid;

\echo ''
\echo '#############################################'
\echo '# 5 · O HELPER INTERNO E EXPOSTO'
\echo '#############################################'
set role anon;
set request.jwt.claims = '{"role":"anon"}';
savepoint s_achado_anon;
\echo '-- ACHADO (05/10/2026): _jantar_enfileirar_whatsapp_confirmacao e SECURITY'
\echo '-- DEFINER, sem _exige_*, e o comentario diz "sem GRANT, nunca exposta" — mas'
\echo '-- nao tem REVOKE FROM PUBLIC, entao anon (so a chave publica do site)'
\echo '-- executa e enfileira WhatsApp pra qualquer convidado cujo id conheca. A'
\echo '-- autoverificacao da migration so olhava as 8 RPCs publicas, nao o helper.'
select _jantar_enfileirar_whatsapp_confirmacao(:'jc_ana'::uuid);
reset role;
reset request.jwt.claims;
select count(*) as avisos_de_confirmacao_da_ana_era_1 from notificacoes where sujeito_id=:'jc_ana'::uuid and tipo='jantar_confirmacao_inscricao';
rollback to s_achado_anon;

reset role;
reset request.jwt.claims;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
