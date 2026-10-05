-- =====================================================================
-- Jantares (criacao com link do Sympla, CEP, logo, capacidade, QR,
-- cadastro na porta, estatistica de confirmacao) e atividade geral x
-- exclusiva · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM — mesmo padrao de 07 e 12.
-- Jantar nao e por evento (tabela global); tudo que este teste cria
-- tem "Cob19" no nome, e as checagens filtram por isso. A parte de
-- atividade cria o proprio evento ('cob19').
--
-- COBRE (migrations sem teste ate 05/10/2026):
--
--   1. jantar_estatisticas_confirmacao: quem e convidado e nunca
--      confirma aparece; confirmou e nao foi; equipe CIO CERRADO fora
--      (20260831190000)
--   2. QR no jantar: check-in pela chave jantar_convidado:<id>
--      (20260902100000)
--   3. cadastro na porta do jantar, reaproveitando gestor por e-mail
--      (20260902210000)
--   4. lista ordenada por nome, capacidade ao confirmar, check de
--      status (20260909130000)
--   5. logo, mensagem e CEP so com digitos (20260909200000,
--      20260909220000)
--   6. sympla_status so 'pendente'/'criado' e o robo removido
--      (20260921090000); criar ja com link vira 'criado'
--      (20260928090000)
--   7. atividade geral x exclusiva (20260902220000); sem o overload
--      orfao de admin_salvar_atividade, e a lista exclusiva reconhecendo
--      o CIO que ja tem rooming (20261005130000, achados de 05/10/2026)
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO
-- ---------------------------------------------------------------------
insert into admins (email,nome,role) values
  ('cob19-admin@teste.invalido','Admin Cob19','admin'),
  ('cob19-staff@teste.invalido','Staff Cob19','staff');

insert into gestores (nome,email,empresa,cargo,perfil) values
  ('Ana Cob19','ana19@teste.invalido','Emp Ana','CIO','CIO'),
  ('Bruno Cob19','bruno19@teste.invalido','Emp Bruno','CIO','CIO'),
  ('Carla Cob19','carla19@teste.invalido','Emp Carla','CIO','CIO'),
  ('Equipe Cob19','equipe19@teste.invalido','CIO Cerrado','Coord','CIO CERRADO')
on conflict (email_norm) do nothing;
select id as g_ana   from gestores where email='ana19@teste.invalido' \gset
select id as g_bruno from gestores where email='bruno19@teste.invalido' \gset
select id as g_carla from gestores where email='carla19@teste.invalido' \gset
select id as g_eq    from gestores where email='equipe19@teste.invalido' \gset

\echo ''
\echo '#############################################'
\echo '# 1 · CRIAR JANTAR: LINK DO SYMPLA, CEP, LOGO'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cob19-staff@teste.invalido","role":"authenticated"}';
savepoint s_jantar_staff;
\echo '-- staff cria jantar — so admin — deve FALHAR'
select jantar_salvar('Patro Cob19');
rollback to s_jantar_staff;

set request.jwt.claims = '{"email":"cob19-admin@teste.invalido","role":"authenticated"}';
\echo '-- jantar criado JA com link do Sympla nasce "criado"; CEP so com digitos — deve PASSAR'
select jantar_salvar('Patro Cob19 Passado', p_data => current_date - 10, p_capacidade => 2,
                     p_sympla_url => ' https://sympla.test/cob19 ', p_cep => '74.000-100',
                     p_mensagem => 'Bem-vindos') ->> 'id' as j_passado \gset
select sympla_status = 'criado' and sympla_criado_em is not null and sympla_url = 'https://sympla.test/cob19'
       and cep = '74000100' and mensagem = 'Bem-vindos' as criado_com_link_ok
from jantar_obter(:'j_passado'::uuid);

\echo '-- sem link nasce pendente; ao ganhar o link na edicao vira criado — deve PASSAR'
select jantar_salvar('Patro Cob19 Futuro', p_data => current_date + 10, p_capacidade => 8) ->> 'id' as j_futuro \gset
select sympla_status = 'pendente' as nasce_pendente_ok from jantar_obter(:'j_futuro'::uuid);
select jantar_salvar('Patro Cob19 Futuro', p_id => :'j_futuro'::uuid, p_data => current_date + 10,
                     p_sympla_url => 'https://sympla.test/futuro') ->> 'ok' as editou;
select sympla_status = 'criado' as virou_criado_ok from jantar_obter(:'j_futuro'::uuid);

savepoint s_status_jantar;
\echo '-- status de jantar fora da lista — deve FALHAR'
select jantar_salvar('Patro Cob19 X', p_status => 'adiado');
rollback to s_status_jantar;

reset role;
reset request.jwt.claims;
savepoint s_sympla_antigo;
\echo '-- o status do robo ("convites_enviados") nao existe mais — deve FALHAR'
update jantares set sympla_status = 'convites_enviados' where id = :'j_futuro'::uuid;
rollback to s_sympla_antigo;
\echo '-- e as funcoes do robo do Sympla foram removidas — deve PASSAR'
select not exists (select 1 from pg_proc where pronamespace='gestao'::regnamespace
                   and proname in ('jantar_listar_para_sympla','jantar_marcar_sympla')) as robo_removido_ok;

set role authenticated;
set request.jwt.claims = '{"email":"cob19-admin@teste.invalido","role":"authenticated"}';
\echo '-- admin define o logo do jantar — deve PASSAR'
select jantar_definir_logo(:'j_futuro'::uuid, ' jantares/cob19/logo.png ') ->> 'ok' = 'true' as logo_ok;
select logo_storage_path = 'jantares/cob19/logo.png' as logo_gravado_ok from jantar_obter(:'j_futuro'::uuid);
set request.jwt.claims = '{"email":"cob19-staff@teste.invalido","role":"authenticated"}';
savepoint s_logo_staff;
\echo '-- staff define logo — so admin — deve FALHAR'
select jantar_definir_logo(:'j_futuro'::uuid, 'x.png');
rollback to s_logo_staff;

\echo ''
\echo '#############################################'
\echo '# 2 · CONVIDADOS: ORDEM, STATUS E CAPACIDADE'
\echo '#############################################'
reset role;
reset request.jwt.claims;
-- jantar passado (capacidade 2): Bruno confirmou e nao foi; Ana foi;
-- Carla foi convidada e nunca respondeu; a equipe tambem foi chamada
insert into jantar_convidados (jantar_id,gestor_id,origem,status) values
  (:'j_passado'::uuid,:'g_bruno'::uuid,'manual','confirmado'),
  (:'j_passado'::uuid,:'g_ana'::uuid,'manual','compareceu'),
  (:'j_passado'::uuid,:'g_carla'::uuid,'manual','convidado'),
  (:'j_passado'::uuid,:'g_eq'::uuid,'manual','convidado');
-- jantar futuro: Carla convidada de novo, Ana sugerida
insert into jantar_convidados (jantar_id,gestor_id,origem,status) values
  (:'j_futuro'::uuid,:'g_carla'::uuid,'manual','convidado'),
  (:'j_futuro'::uuid,:'g_ana'::uuid,'manual','sugerido');
select id as jc_carla_passado from jantar_convidados where jantar_id=:'j_passado'::uuid and gestor_id=:'g_carla'::uuid \gset
select id as jc_ana_futuro    from jantar_convidados where jantar_id=:'j_futuro'::uuid  and gestor_id=:'g_ana'::uuid \gset

set role authenticated;
set request.jwt.claims = '{"email":"cob19-staff@teste.invalido","role":"authenticated"}';
\echo '-- lista do jantar ordenada por nome — deve PASSAR'
select array_agg(nome order by ordem) = array['ANA COB19','BRUNO COB19','CARLA COB19','EQUIPE COB19'] as ordem_ok
from (select nome, row_number() over () as ordem from jantar_convidados_listar(:'j_passado'::uuid)) x;

savepoint s_capacidade;
\echo '-- jantar de 2 lugares ja com 2 (confirmado+compareceu): confirmar a Carla — deve FALHAR'
select jantar_marcar_convidado(:'jc_carla_passado'::uuid, 'confirmado');
rollback to s_capacidade;
savepoint s_status_conv;
\echo '-- status de convidado fora da lista — deve FALHAR'
select jantar_marcar_convidado(:'jc_ana_futuro'::uuid, 'talvez');
rollback to s_status_conv;
\echo '-- recusar nao esbarra em capacidade — deve PASSAR'
select jantar_marcar_convidado(:'jc_carla_passado'::uuid, 'recusado') ->> 'ok' = 'true' as recusou_ok;
select jantar_marcar_convidado(:'jc_carla_passado'::uuid, 'convidado') ->> 'ok' as voltou_convidado;

\echo ''
\echo '#############################################'
\echo '# 3 · ESTATISTICA DE CONFIRMACAO (31/08)'
\echo '#############################################'
\echo '-- Carla: 2 convites, 0 confirmacoes — aparece mesmo sem nunca confirmar — deve PASSAR'
select n_convites = 2 and n_confirmados = 0 and taxa = 0 as carla_ok
from jantar_estatisticas_confirmacao(100000) where gestor_id=:'g_carla'::uuid;
\echo '-- Bruno: confirmou num jantar que ja passou e nao virou compareceu — deve PASSAR'
select n_convites = 1 and n_confirmados = 1 and n_compareceu = 0 and n_sem_comparecimento = 1 and taxa = 100 as bruno_ok
from jantar_estatisticas_confirmacao(100000) where gestor_id=:'g_bruno'::uuid;
\echo '-- Ana: sugerida no futuro NAO conta como convite; compareceu no passado — deve PASSAR'
select n_convites = 1 and n_compareceu = 1 and n_sem_comparecimento = 0 as ana_ok
from jantar_estatisticas_confirmacao(100000) where gestor_id=:'g_ana'::uuid;
\echo '-- equipe CIO CERRADO fica fora do ranking — deve PASSAR'
select not exists (select 1 from jantar_estatisticas_confirmacao(100000) where gestor_id=:'g_eq'::uuid) as equipe_fora_ok;

\echo ''
\echo '#############################################'
\echo '# 4 · CHECK-IN: QR E CADASTRO NA PORTA'
\echo '#############################################'
\echo '-- QR da Carla no jantar futuro marca compareceu — deve PASSAR'
select (r ->> 'ja_estava')::boolean = false and r ->> 'nome' = 'CARLA COB19' as qr_ok
from jantar_checkin_por_qr('jantar_convidado:' || (select id from jantar_convidados_listar(:'j_futuro'::uuid) where gestor_id=:'g_carla'::uuid)) r;
\echo '-- ler o mesmo QR de novo: ja estava — deve PASSAR'
select (jantar_checkin_por_qr('jantar_convidado:' || (select id from jantar_convidados_listar(:'j_futuro'::uuid) where gestor_id=:'g_carla'::uuid)) ->> 'ja_estava')::boolean as qr_repetido_ok;
savepoint s_qr_evento;
\echo '-- cracha do evento (participante:) nao e de jantar — deve FALHAR'
select jantar_checkin_por_qr('participante:' || gen_random_uuid());
rollback to s_qr_evento;

\echo '-- quem nao estava na lista se cadastra na porta: entra como compareceu — deve PASSAR'
select (jantar_checkin_cadastrar(:'j_futuro'::uuid, 'Daniel Cob19', 'Emp Daniel', 'daniel19@teste.invalido') ->> 'gestor_reaproveitado')::boolean = false as novo_na_porta_ok;
\echo '-- Bruno (ja na base) se cadastra na porta pelo e-mail: reaproveita o gestor — deve PASSAR'
select (jantar_checkin_cadastrar(:'j_futuro'::uuid, 'Bruno', null, ' BRUNO19@teste.invalido ') ->> 'gestor_reaproveitado')::boolean as reaproveitou_ok;
select count(*) filter (where status='compareceu') = 3 as tres_presentes_ok
from jantar_convidados_listar(:'j_futuro'::uuid);
savepoint s_porta_sem_nome;
\echo '-- cadastro na porta sem nome — deve FALHAR'
select jantar_checkin_cadastrar(:'j_futuro'::uuid, '  ');
rollback to s_porta_sem_nome;

\echo ''
\echo '#############################################'
\echo '# 5 · ATIVIDADE GERAL x EXCLUSIVA'
\echo '#############################################'
reset role;
reset request.jwt.claims;
insert into eventos (slug,nome,status,data_inicio,data_fim)
values ('cob19','Cobertura 19','aberto','2027-08-12','2027-08-16');
select id as ev from eventos where slug='cob19' \gset
insert into admin_eventos (admin_id,evento_id)
select id, :'ev'::uuid from admins where email='cob19-staff@teste.invalido';
insert into participantes (evento_id,gestor_id,status,origem,aprovado_em) values
  (:'ev'::uuid,:'g_ana'::uuid,'aprovado','manual',now()),
  (:'ev'::uuid,:'g_bruno'::uuid,'aprovado','manual',now()),
  (:'ev'::uuid,:'g_carla'::uuid,'aprovado','manual',now());
select id as p_ana   from participantes where evento_id=:'ev'::uuid and gestor_id=:'g_ana'::uuid \gset
select id as p_bruno from participantes where evento_id=:'ev'::uuid and gestor_id=:'g_bruno'::uuid \gset
select id as p_carla from participantes where evento_id=:'ev'::uuid and gestor_id=:'g_carla'::uuid \gset

set role authenticated;
set request.jwt.claims = '{"email":"cob19-admin@teste.invalido","role":"authenticated"}';
\echo '-- cria uma atividade geral e uma exclusiva; tipo invalido cai em geral — deve PASSAR'
select admin_salvar_atividade(null,'cob19','Palestra Cob19','2027-08-13','09:00','10:00','Auditorio','geral') ->> 'id' as at_geral \gset
select admin_salvar_atividade(null,'cob19','Trilha Cob19','2027-08-13','11:00','12:00','Trilha','exclusiva') ->> 'id' as at_excl \gset
select admin_salvar_atividade(null,'cob19','Outra Cob19','2027-08-14','09:00','10:00','Sala','vip') ->> 'id' as at_vip \gset
select bool_and(case nome when 'Trilha Cob19' then tipo_presenca='exclusiva' else tipo_presenca='geral' end) as tipos_ok
from admin_listar_atividades('cob19');

\echo '-- chamada sem p_tipo_presenca: uma funcao so (a de 7 parametros saiu —'
\echo '-- 20261005130000), cai em geral — deve PASSAR'
select admin_salvar_atividade(null,'cob19','Sem Tipo Cob19','2027-08-14','09:00','10:00','Sala') ->> 'ok' = 'true' as sem_tipo_ok;

set request.jwt.claims = '{"email":"cob19-staff@teste.invalido","role":"authenticated"}';
\echo '-- staff do evento define a lista fechada: Ana e Bruno — deve PASSAR'
select (admin_definir_convidados_atividade(:'at_excl'::uuid, array[:'p_ana'::uuid, :'p_bruno'::uuid]) ->> 'na_lista')::int = 2 as lista_ok;
select count(*) filter (where marcado) = 2 as marcados_ok from admin_listar_convidados_atividade(:'at_excl'::uuid);
\echo '-- na geral, os 3 CIOs sao esperados; na exclusiva, so os 2 da lista — deve PASSAR'
select count(*) = 3 as geral_3_ok from atividade_checkin_listar(:'at_geral'::uuid);
select count(*) = 2 as exclusiva_2_ok from atividade_checkin_listar(:'at_excl'::uuid);
savepoint s_fora_da_lista;
\echo '-- Carla (fora da lista) faz check-in na exclusiva — deve FALHAR'
select atividade_checkin_registrar(:'at_excl'::uuid, 'participante:' || :'p_carla');
rollback to s_fora_da_lista;
\echo '-- Ana (na lista) faz check-in na exclusiva — deve PASSAR'
select (atividade_checkin_registrar(:'at_excl'::uuid, 'participante:' || :'p_ana') ->> 'ja_estava')::boolean = false as ana_entrou_ok;
\echo '-- redefinir a lista so com a Ana tira o Bruno — deve PASSAR'
select (admin_definir_convidados_atividade(:'at_excl'::uuid, array[:'p_ana'::uuid]) ->> 'removidos')::int = 1 as tirou_bruno_ok;

-- Bruno preenche o rooming (reserva com ele dentro) — e o que todo CIO
-- faz antes do evento
reset role;
reset request.jwt.claims;
insert into atividade_convidados (atividade_id,participante_id) values (:'at_excl'::uuid,:'p_bruno'::uuid);
select _garantir_reserva(:'p_bruno'::uuid) as res_bruno \gset
insert into ocupantes (reserva_id,nome,tipo) values
  (:'res_bruno'::uuid,'Bruno Cob19','titular'),
  (:'res_bruno'::uuid,'Esposa Bruno Cob19','adulto');
select 'ocupante:' || id as cracha_bruno from ocupantes where reserva_id=:'res_bruno'::uuid and tipo='titular' \gset
select 'ocupante:' || id as cracha_familiar from ocupantes where reserva_id=:'res_bruno'::uuid and tipo='adulto' \gset

set role authenticated;
set request.jwt.claims = '{"email":"cob19-staff@teste.invalido","role":"authenticated"}';
\echo '-- Bruno esta na lista fechada e ja tem rooming: em v_esperados ele virou'
\echo '-- "ocupante:<id>". Continua na lista da porta (antes sumia — 20261005130000)'
\echo '-- e o check-in pelo cracha do quarto entra — deve PASSAR'
select count(*) filter (where nome ilike 'bruno%') = 1 and count(*) = 2 as bruno_na_porta_ok
from atividade_checkin_listar(:'at_excl'::uuid);
select (atividade_checkin_registrar(:'at_excl'::uuid, :'cracha_bruno') ->> 'ja_estava')::boolean = false as bruno_entrou_ok;
\echo '-- a familiar que dorme no quarto do Bruno NAO herda o lugar dele na lista — deve FALHAR'
savepoint s_familiar;
select atividade_checkin_registrar(:'at_excl'::uuid, :'cracha_familiar');
rollback to s_familiar;

reset role;
reset request.jwt.claims;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
