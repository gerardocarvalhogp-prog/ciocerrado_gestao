-- =====================================================================
-- Webhook do Autentique (contrato assinado), link do PDF no painel,
-- mailing do evento inteiro e pesquisa de perfil no mailing
-- · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM — mesmo padrao de 07 e 12.
-- Cria o proprio evento ('cob22'). Nao chama o Autentique: o teste e da
-- RPC que a Edge Function chama depois de reconferir la.
--
-- COBRE (migrations sem teste ate 05/10/2026):
--
--   1. webhook_contrato_assinado: so a chave de servico chama (nem
--      admin logado), marca assinado, enfileira o aviso UMA vez, e'
--      idempotente na reentrega (20261001140000)
--   2. o link do PDF assinado substitui o link generico e aparece no
--      painel; reentrega nunca sobrescreve link ja gravado
--      (20261001170000)
--   3. o aviso sai com corpo pronto e o link do rooming do evento
--      certo (20261001180000)
--   4. admin_mailing_evento: todas as sessoes numa consulta, e-mail
--      interno mascarado, rotulo da sessao vence o perfil
--      (20261001270000)
--   5. admin_rel_pesquisa com o tipo de ingresso na frente e quem nao
--      respondeu tambem na lista (20261001280000)
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO
-- ---------------------------------------------------------------------
insert into eventos (slug,nome,status) values ('cob22','Cobertura 22','aberto');
select id as ev from eventos where slug='cob22' \gset

insert into admins (email,nome,role) values
  ('cob22-admin@teste.invalido','Admin Cob22','admin'),
  ('cob22-staff@teste.invalido','Staff Cob22','staff');
insert into admin_eventos (admin_id,evento_id)
select id, :'ev'::uuid from admins where email='cob22-staff@teste.invalido';

insert into gestores (nome,email,empresa,cargo,telefone,perfil) values
  ('Ana Cob22','ana22@teste.invalido','Emp Ana','CIO','62999990001','CLIENTE'),
  ('Bruno Cob22','bruno22@teste.invalido','Emp Bruno','CTO',null,'CONVIDADO CIO CERRADO'),
  ('Avulso Cob22','avulso.cob22@interno.ciocerrado.com.br','Emp Avulso','CIO',null,'CONVIDADO')
on conflict (email_norm) do nothing;
insert into participantes (evento_id,gestor_id,status,origem,aprovado_em)
select :'ev'::uuid, id, 'aprovado','manual',now() from gestores
 where email in ('ana22@teste.invalido','bruno22@teste.invalido','avulso.cob22@interno.ciocerrado.com.br');
select pa.id as p_ana   from participantes pa join gestores g on g.id=pa.gestor_id where g.email='ana22@teste.invalido' and pa.evento_id=:'ev'::uuid \gset
select pa.id as p_bruno from participantes pa join gestores g on g.id=pa.gestor_id where g.email='bruno22@teste.invalido' and pa.evento_id=:'ev'::uuid \gset
select pa.id as p_av    from participantes pa join gestores g on g.id=pa.gestor_id where g.email like 'avulso.cob22@%' and pa.evento_id=:'ev'::uuid \gset

insert into contratos (participante_id,autentique_id,autentique_url,status,enviado_em) values
  (:'p_ana'::uuid,'aut-cob22-ana','https://app.autentique.test/documentos/aut-cob22-ana','enviado',now()),
  (:'p_bruno'::uuid,'aut-cob22-bruno',null,'enviado',now());

\echo ''
\echo '#############################################'
\echo '# 1 · QUEM CHAMA O WEBHOOK'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cob22-admin@teste.invalido","role":"authenticated"}';
savepoint s_webhook_admin;
\echo '-- nem admin logado chama a RPC do webhook (GRANT so pra service_role) — deve FALHAR'
select webhook_contrato_assinado('aut-cob22-ana');
rollback to s_webhook_admin;

set role anon;
set request.jwt.claims = '{"role":"anon"}';
savepoint s_webhook_anon;
\echo '-- anon (o Autentique sem passar pela Edge Function) — deve FALHAR'
select webhook_contrato_assinado('aut-cob22-ana');
rollback to s_webhook_anon;

\echo ''
\echo '#############################################'
\echo '# 2 · ASSINADO, LINK DO PDF E AVISO'
\echo '#############################################'
set role service_role;
set request.jwt.claims = '{"role":"service_role"}';
savepoint s_webhook_vazio;
\echo '-- autentique_id vazio — deve FALHAR'
select webhook_contrato_assinado('  ');
rollback to s_webhook_vazio;
savepoint s_webhook_inexistente;
\echo '-- documento que nao e de nenhum contrato — deve FALHAR'
select webhook_contrato_assinado('aut-nao-existe');
rollback to s_webhook_inexistente;

\echo '-- Ana assinou: a Edge Function manda o link do PDF assinado — deve PASSAR'
select (webhook_contrato_assinado('aut-cob22-ana', 'https://autentique.test/pdf/ana-assinado.pdf') ->> 'ja_estava_assinado')::boolean = false as assinou_ok;
\echo '-- reentrega do mesmo webhook com OUTRO link: idempotente, nao troca o link — deve PASSAR'
select (webhook_contrato_assinado('aut-cob22-ana', 'https://autentique.test/pdf/outro.pdf') ->> 'ja_estava_assinado')::boolean as reentrega_ok;
\echo '-- Bruno assinou mas o PDF ainda nao fechou (sem link); na reentrega o link chega — deve PASSAR'
select webhook_contrato_assinado('aut-cob22-bruno') ->> 'ok' = 'true' as bruno_sem_link_ok;
select webhook_contrato_assinado('aut-cob22-bruno', 'https://autentique.test/pdf/bruno.pdf') ->> 'ok' = 'true' as bruno_link_depois_ok;

reset role;
reset request.jwt.claims;
\echo '-- contratos: assinados, link do PDF (o da Ana substituiu o generico; o do Bruno completou o vazio) — deve PASSAR'
select bool_and(status='assinado' and assinado_em is not null) and
       bool_and(case participante_id when :'p_ana'::uuid then autentique_url='https://autentique.test/pdf/ana-assinado.pdf'
                                     else autentique_url='https://autentique.test/pdf/bruno.pdf' end) as contratos_ok
from contratos where participante_id in (:'p_ana'::uuid, :'p_bruno'::uuid);
\echo '-- UM aviso por pessoa (reentrega nao duplica), com corpo pronto e o link do rooming do cob22 — deve PASSAR'
select count(*) = 1 and bool_and(corpo like '%rooming.html?evento=cob22%' and corpo like 'Olá, ANA COB22.%') as aviso_ana_ok
from notificacoes where destinatario='ana22@teste.invalido' and tipo='contrato_assinado';
select count(*) = 1 as aviso_bruno_ok from notificacoes where destinatario='bruno22@teste.invalido' and tipo='contrato_assinado';

set role authenticated;
set request.jwt.claims = '{"email":"cob22-staff@teste.invalido","role":"authenticated"}';
\echo '-- painel mostra o link do PDF de quem assinou; quem nao tem contrato fica sem — deve PASSAR'
select bool_and(case participante_id
                  when :'p_ana'::uuid then status_contrato='assinado' and autentique_url like '%ana-assinado.pdf'
                  when :'p_av'::uuid  then autentique_url is null
                  else true end) and count(*) = 3 as painel_ok
from admin_rel_painel('cob22');

\echo ''
\echo '#############################################'
\echo '# 3 · MAILING DO EVENTO INTEIRO'
\echo '#############################################'
reset role;
reset request.jwt.claims;
insert into patrocinadores (evento_id,empresa,status) values
  (:'ev'::uuid,'Patro Cob22 A','ativo'), (:'ev'::uuid,'Patro Cob22 B','ativo');
insert into sessoes (evento_id,patrocinador_id,tipo,vagas)
select :'ev'::uuid, id, 'mesa_redonda', 5 from patrocinadores where evento_id=:'ev'::uuid and empresa='Patro Cob22 A';
insert into sessoes (evento_id,patrocinador_id,tipo,vagas)
select :'ev'::uuid, id, 'jantar', 5 from patrocinadores where evento_id=:'ev'::uuid and empresa='Patro Cob22 B';
insert into sessao_convidados (sessao_id,participante_id,origem,rotulo)
select s.id, :'p_ana'::uuid, 'admin', 'VIP DA MESA' from sessoes s join patrocinadores p on p.id=s.patrocinador_id where p.empresa='Patro Cob22 A';
insert into sessao_convidados (sessao_id,participante_id,origem)
select s.id, :'p_av'::uuid, 'admin' from sessoes s join patrocinadores p on p.id=s.patrocinador_id where p.empresa='Patro Cob22 A';
insert into sessao_convidados (sessao_id,participante_id,origem)
select s.id, :'p_bruno'::uuid, 'admin' from sessoes s join patrocinadores p on p.id=s.patrocinador_id where p.empresa='Patro Cob22 B';
insert into sessao_convidados (sessao_id,participante_id,origem,status)
select s.id, :'p_ana'::uuid, 'admin', 'removido' from sessoes s join patrocinadores p on p.id=s.patrocinador_id where p.empresa='Patro Cob22 B';

set role authenticated;
set request.jwt.claims = '{"email":"cob22-staff@teste.invalido","role":"authenticated"}';
\echo '-- 3 confirmados em 2 patrocinadores, numa consulta so; removido fica de fora — deve PASSAR'
select count(*) = 3 and count(distinct patrocinador) = 2 as mailing_ok from admin_mailing_evento('cob22');
\echo '-- rotulo da sessao vence o perfil; e-mail interno sai mascarado — deve PASSAR'
select rotulo = 'VIP DA MESA' as rotulo_ok from admin_mailing_evento('cob22') where nome='ANA COB22';
select email is null as mascara_ok from admin_mailing_evento('cob22') where nome='AVULSO COB22';
select rotulo = 'CONVIDADO CIO CERRADO' and tipo = 'jantar' as perfil_ok from admin_mailing_evento('cob22') where nome='BRUNO COB22';

\echo ''
\echo '#############################################'
\echo '# 4 · PESQUISA DE PERFIL NO MAILING'
\echo '#############################################'
reset role;
reset request.jwt.claims;
insert into participante_perfil (participante_id,faturamento,orcamento_ti,respostas,consentimento_lgpd)
values (:'p_ana'::uuid,'R$ 100 mi a 500 mi','R$ 5 mi','{"investimentos":{"IA":true},"dispositivos":"500"}'::jsonb,true);
set role authenticated;
set request.jwt.claims = '{"email":"cob22-staff@teste.invalido","role":"authenticated"}';
\echo '-- quem respondeu vem com faturamento e investimentos; tipo de ingresso na frente — deve PASSAR'
select perfil_ingresso = 'CLIENTE' and respondeu and faturamento = 'R$ 100 mi a 500 mi'
       and investimentos = '{"IA":true}'::jsonb and dispositivos = '500' and consentimento_lgpd as ana_pesquisa_ok
from admin_rel_pesquisa('cob22') where nome='ANA COB22';
\echo '-- quem nao respondeu tambem esta (mailing completo), com respondeu=false — deve PASSAR'
select count(*) = 3 and count(*) filter (where not respondeu) = 2 as todos_no_mailing_ok from admin_rel_pesquisa('cob22');

reset role;
reset request.jwt.claims;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
