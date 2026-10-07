-- =====================================================================
-- Usuario do patrocinador cadastrado como a tela cadastra HOJE (so pela
-- empresa, sem patrocinador_id) aparece em todo lugar · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM — mesmo padrao de 07 e 12.
-- Cria o proprio evento ('cob25').
--
-- POR QUE ESTE TESTE EXISTE
--
-- Achado ao vivo pelo organizador em 07/10/2026: cadastrou e-mail valido
-- pro patrocinador e a cobranca disse "Nenhum e-mail de contato ativo".
-- Desde 20260909100000 o login e da EMPRESA (admin_salvar_usuario_patro
-- grava so empresa_id); seis lugares ainda procuravam pelo vinculo antigo
-- (usuarios_patrocinador.patrocinador_id), vazio pra todo usuario novo.
-- Os testes 14 e 18 nao pegaram porque montavam o usuario do jeito
-- antigo, com patrocinador_id. Aqui o usuario entra pela funcao da tela.
--
-- COBRE (20261007090000): previa e envio de cobranca, e-mail na fatura
-- (Financeiro), planilha do app do evento, cracha (v_etiquetas) e lista
-- do check-in (v_esperados).
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO
-- ---------------------------------------------------------------------
insert into eventos (slug,nome,status,data_inicio,data_fim)
values ('cob25','Cobertura 25','aberto','2027-08-12','2027-08-16');
select id as ev from eventos where slug='cob25' \gset
insert into precos (evento_id,item,valor) values (:'ev'::uuid,'quarto_duplo',1000);
insert into prazos_evento (evento_id,etapa_chave,dias_atencao,dias_atrasado)
values (:'ev'::uuid,'contrato_patrocinio_assinado',1,2);
insert into quartos (evento_id,numero,tipo,capacidade,status,finalidade)
values (:'ev'::uuid,'251','duplo',2,'disponivel','avulso');
insert into admins (email,nome,role) values ('cob25-admin@teste.invalido','Admin Cob25','admin');

set role authenticated;
set request.jwt.claims = '{"email":"cob25-admin@teste.invalido","role":"authenticated"}';
-- patrocinador e usuario entram pelas MESMAS funcoes que admin.html chama
select admin_salvar_patrocinador('cob25','Patro Cob25') as r_pat \gset
select (:'r_pat'::jsonb ->> 'id') as pat, (:'r_pat'::jsonb ->> 'empresa_id') as emp \gset
select admin_salvar_usuario_patro(:'emp'::uuid, 'contato25@teste.invalido', 'Contato Cob25') ->> 'ok' as usuario;
reset role;
reset request.jwt.claims;

\echo '-- o usuario nasceu como a tela cria hoje: empresa_id, SEM patrocinador_id — deve PASSAR'
select patrocinador_id is null and empresa_id = :'emp'::uuid as cadastro_atual_ok
from usuarios_patrocinador where email = 'contato25@teste.invalido';

\echo ''
\echo '#############################################'
\echo '# 1 · CRACHA E CHECK-IN'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cob25-admin@teste.invalido","role":"authenticated"}';
\echo '-- o contato do patrocinador sai no cracha (antes: sumia) — deve PASSAR'
select count(*) = 1 and bool_and(categoria = 'PATROCINADOR' and empresa = 'Patro Cob25') as cracha_ok
from admin_etiquetas('cob25') where pessoa_key like 'usuario_patro:%';
\echo '-- e na lista do check-in — deve PASSAR'
select count(*) = 1 as checkin_ok
from checkin_listar('cob25') where pessoa_key like 'usuario_patro:%';

\echo ''
\echo '#############################################'
\echo '# 2 · PLANILHA DO APP DO EVENTO'
\echo '#############################################'
\echo '-- o contato entra na planilha de usuarios do app — deve PASSAR'
select count(*) = 1 as app_ok from admin_exportar_usuarios_app('cob25') where email = 'contato25@teste.invalido';

\echo ''
\echo '#############################################'
\echo '# 3 · COBRANCA'
\echo '#############################################'
\echo '-- previa da cobranca do contrato de patrocinio acha o e-mail (era o achado) — deve PASSAR'
select p::text like '%contato25@teste.invalido%' as previa_ok
from admin_preparar_cobranca(:'pat'::uuid, 'contrato_patrocinio_assinado') p;
\echo '-- e o envio enfileira pra ele — deve PASSAR'
select (admin_disparar_cobranca(:'pat'::uuid,'contrato_patrocinio_assinado','Assine','Corpo') ->> 'enfileiradas')::int = 1 as enfileirou_ok;

\echo ''
\echo '#############################################'
\echo '# 4 · FINANCEIRO'
\echo '#############################################'
-- o proprio contato (login da empresa) compra um quarto extra
set request.jwt.claims = '{"email":"contato25@teste.invalido","role":"authenticated"}';
select patro_comprar_quarto(:'pat'::uuid, 'duplo') ->> 'ok' as comprou;
set request.jwt.claims = '{"email":"cob25-admin@teste.invalido","role":"authenticated"}';
\echo '-- a fatura do patrocinador sai com o e-mail do contato (antes: vazio) — deve PASSAR'
select total = 1000 and email = 'contato25@teste.invalido' as fatura_email_ok
from admin_listar_faturas('cob25') where tipo = 'patrocinador';

reset role;
reset request.jwt.claims;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
