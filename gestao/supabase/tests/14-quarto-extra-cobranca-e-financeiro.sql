-- =====================================================================
-- Fatura do quarto extra do patrocinador, "familiar" na previa,
-- financeiro so de quem deve, pagamento da cota e cobranca que nao sai
-- pra quem ja resolveu · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM — mesmo padrao de 07 e 12.
-- Cria o proprio evento ('cob14'), com tabela de precos propria — nao
-- depende do preco cadastrado em evento nenhum.
--
-- COBRE (migrations sem teste ate 05/10/2026):
--
--   1. "Acompanhante" vira "Familiar" no texto da previa da fatura,
--      sem mudar o calculo (20260901110000)
--   2. quarto extra do patrocinador entra e sai da fatura
--      (20260902160000)
--   3. Financeiro nao lista fatura de total zero (20260902190000)
--   4. contrato da cota: valor sugerido, valor contratado, status de
--      pagamento e "vencido" calculado (20260909140000)
--   5. cobranca grava o sujeito, bloqueia reenvio em 3 dias, e e'
--      pulada no envio se a pendencia ja foi resolvida; a lista mostra
--      quando foi a ultima cobranca (20260901150000)
--   6. staff de outro evento nao le o financeiro da cota (20261005110000)
--      nem monta a previa de cobranca (20261005150000)
--
-- A compra de quarto extra pelo CIO (20260901160000, refeita em
-- 20260930140000, consertada em 20261005100000) esta no 13.
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO
-- ---------------------------------------------------------------------
insert into eventos (slug,nome,status,data_inicio,data_fim)
values ('cob14','Cobertura 14','aberto','2027-08-12','2027-08-16');
select id as ev from eventos where slug='cob14' \gset

insert into precos (evento_id,item,valor) values
  (:'ev'::uuid,'quarto_duplo',1000),
  (:'ev'::uuid,'acompanhante_adulto',500),
  (:'ev'::uuid,'transfer',100);

insert into prazos_evento (evento_id,etapa_chave,dias_atencao,dias_atrasado)
values (:'ev'::uuid,'contrato_assinado',1,2);

insert into admins (email,nome,role) values
  ('cob14-admin@teste.invalido','Admin Cob14','admin'),
  ('cob14-staff@teste.invalido','Staff Cob14','staff'),
  ('cob14-fora@teste.invalido','Staff de outro evento','staff');
insert into admin_eventos (admin_id,evento_id)
select id, :'ev'::uuid from admins where email='cob14-staff@teste.invalido';

insert into cotas (evento_id,nome,ordem_prioridade) values (:'ev'::uuid,'Ouro Cob14',1);
select id as cota from cotas where evento_id=:'ev'::uuid \gset

insert into patrocinadores (evento_id,cota_id,empresa,status)
values (:'ev'::uuid,:'cota'::uuid,'Patro Cob14','ativo');
select id as pat from patrocinadores where empresa='Patro Cob14' and evento_id=:'ev'::uuid \gset
insert into usuarios_patrocinador (patrocinador_id,email,nome)
values (:'pat'::uuid,'patro14@teste.invalido','Usuario Patro14');

insert into gestores (nome,email,empresa,cargo)
values ('CIO Cob Quatorze','cio14@teste.invalido','Industria Quatorze','CIO')
on conflict (email_norm) do nothing;
insert into participantes (evento_id,gestor_id,status,origem,aprovado_em,created_at)
select :'ev'::uuid, id, 'aprovado','manual', now() - interval '5 days', now() - interval '5 days'
from gestores where email='cio14@teste.invalido';
select pa.id as part from participantes pa join gestores g on g.id=pa.gestor_id
 where g.email='cio14@teste.invalido' and pa.evento_id=:'ev'::uuid \gset

insert into quartos (evento_id,numero,tipo,capacidade,status,finalidade)
values (:'ev'::uuid,'401','duplo',2,'disponivel','avulso');

\echo ''
\echo '#############################################'
\echo '# 1 · "FAMILIAR" NA PREVIA DA FATURA'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cio14@teste.invalido","role":"authenticated"}';
\echo '-- 2 familiares adultos: 1 cortesia + 1 pago (500) — deve PASSAR'
select (p ->> 'total')::numeric = 500 as total_500_ok,
       p -> 'itens' -> 0 ->> 'descricao' = 'Familiar adulto · cortesia' as cortesia_ok,
       p -> 'itens' -> 1 ->> 'descricao' = 'Familiar adulto' as pago_ok,
       p::text not ilike '%acompanhante%' as sem_acompanhante_ok
from part_previa_fatura('cob14', '[{"nome":"A"},{"nome":"B"}]'::jsonb) p;

\echo ''
\echo '#############################################'
\echo '# 2 · QUARTO EXTRA DO PATROCINADOR GERA (E TIRA) COBRANCA'
\echo '#############################################'
set request.jwt.claims = '{"email":"patro14@teste.invalido","role":"authenticated"}';
\echo '-- patrocinador compra o duplo avulso — deve PASSAR'
select patro_comprar_quarto(:'pat'::uuid, 'duplo') ->> 'reserva_id' as res_extra \gset
select :'res_extra' <> '' as comprou_ok;

set request.jwt.claims = '{"email":"cob14-staff@teste.invalido","role":"authenticated"}';
\echo '-- o Financeiro mostra a fatura do patrocinador: 1000, com o quarto extra — deve PASSAR'
select total = 1000 and itens like 'Quarto extra duplo%' as fatura_ok
from admin_listar_faturas('cob14') where tipo='patrocinador';

set request.jwt.claims = '{"email":"patro14@teste.invalido","role":"authenticated"}';
\echo '-- patrocinador cancela o quarto extra — deve PASSAR'
select patro_cancelar_quarto_extra(:'res_extra'::uuid) ->> 'ok' = 'true' as cancelou_ok;

set request.jwt.claims = '{"email":"cob14-staff@teste.invalido","role":"authenticated"}';
\echo '-- a cobranca sumiu junto — deve PASSAR'
select not exists (select 1 from admin_listar_faturas('cob14') where tipo='patrocinador') as fatura_sumiu_ok;

\echo ''
\echo '#############################################'
\echo '# 3 · FINANCEIRO SO MOSTRA QUEM DEVE ALGO'
\echo '#############################################'
reset role;
reset request.jwt.claims;
-- fatura estimada de total zero, como o recalculo do CIO deixa
insert into faturas (evento_id,participante_id,status,total)
values (:'ev'::uuid,:'part'::uuid,'estimada',0);
set role authenticated;
set request.jwt.claims = '{"email":"cob14-staff@teste.invalido","role":"authenticated"}';
\echo '-- fatura de total zero nao aparece no Financeiro — deve PASSAR'
select count(*) = 0 as zero_escondida_ok from admin_listar_faturas('cob14');

\echo ''
\echo '#############################################'
\echo '# 4 · CONTRATO DA COTA: VALOR, PAGAMENTO, VENCIDO'
\echo '#############################################'
set request.jwt.claims = '{"email":"cob14-admin@teste.invalido","role":"authenticated"}';
\echo '-- admin grava o valor sugerido da cota (preco de tabela) — deve PASSAR'
select admin_salvar_cota('cob14','Ouro Cob14',1, p_valor_sugerido => 80000) ->> 'ok' = 'true' as salvou_cota_ok;
select valor_sugerido = 80000 as valor_sugerido_ok from admin_listar_cotas('cob14');

\echo '-- contrato de 50 mil, em aberto, vencido ontem — deve PASSAR'
select admin_definir_pagamento_patrocinador(:'pat'::uuid, 50000, 'aberto', current_date - 1) ->> 'ok' = 'true' as gravou_ok;
select vencido and valor_contratado = 50000 as aparece_vencido_ok
from admin_listar_financeiro_cotas('cob14');
select (r ->> 'vencido')::numeric = 50000 and (r ->> 'qtd_vencidas')::int = 1
       and (r ->> 'em_aberto')::numeric = 50000 as resumo_vencido_ok
from admin_financeiro_cotas_resumo('cob14') r;

\echo '-- pago: deixa de ser vencido e entra no "pago" — deve PASSAR'
select admin_definir_pagamento_patrocinador(:'pat'::uuid, null, 'pago', null, current_date) ->> 'ok' as pagou;
select not vencido and data_pagamento = current_date as pago_ok from admin_listar_financeiro_cotas('cob14');
select (r ->> 'pago')::numeric = 50000 and (r ->> 'vencido')::numeric = 0 as resumo_pago_ok
from admin_financeiro_cotas_resumo('cob14') r;

\echo '-- volta pra aberto por engano: a data de pagamento e apagada junto — deve PASSAR'
select admin_definir_pagamento_patrocinador(:'pat'::uuid, null, 'aberto') ->> 'ok' as reabriu;
select data_pagamento is null and valor_contratado = 50000 as reabriu_ok from admin_listar_financeiro_cotas('cob14');

savepoint s_pag_inv;
\echo '-- "vencido" nao e status gravavel (e calculado) — deve FALHAR'
select admin_definir_pagamento_patrocinador(:'pat'::uuid, null, 'vencido');
rollback to s_pag_inv;

set request.jwt.claims = '{"email":"cob14-staff@teste.invalido","role":"authenticated"}';
savepoint s_pag_staff;
\echo '-- staff le o financeiro mas nao grava pagamento — deve FALHAR'
select admin_definir_pagamento_patrocinador(:'pat'::uuid, 1, 'pago');
rollback to s_pag_staff;

set request.jwt.claims = '{"email":"cob14-fora@teste.invalido","role":"authenticated"}';
savepoint s_fin_fora;
\echo '-- staff de OUTRO evento le o contrato das cotas do cob14 (20261005110000) — deve FALHAR'
select count(*) from admin_listar_financeiro_cotas('cob14');
rollback to s_fin_fora;
savepoint s_resumo_fora;
\echo '-- nem o resumo financeiro — deve FALHAR'
select admin_financeiro_cotas_resumo('cob14');
rollback to s_resumo_fora;

\echo ''
\echo '#############################################'
\echo '# 5 · COBRANCA NAO SAI PRA QUEM JA RESOLVEU'
\echo '#############################################'
set request.jwt.claims = '{"email":"cob14-admin@teste.invalido","role":"authenticated"}';
\echo '-- contrato do CIO pendente ha 5 dias: aparece na lista, nunca cobrado — deve PASSAR'
select ultima_cobranca_em is null as nunca_cobrado_ok
from admin_pendencias_lista('cob14','contrato_assinado') where sujeito_id=:'part'::uuid;

set request.jwt.claims = '{"email":"cob14-staff@teste.invalido","role":"authenticated"}';
\echo '-- staff do evento monta a previa da cobranca, com o e-mail do CIO — deve PASSAR'
select admin_preparar_cobranca(:'part'::uuid,'contrato_assinado') ::text like '%cio14@teste.invalido%' as previa_ok;
set request.jwt.claims = '{"email":"cob14-fora@teste.invalido","role":"authenticated"}';
savepoint s_previa_fora;
\echo '-- staff de OUTRO evento monta a previa (e veria o e-mail) — 20261005150000 — deve FALHAR'
select admin_preparar_cobranca(:'part'::uuid,'contrato_assinado');
rollback to s_previa_fora;
set request.jwt.claims = '{"email":"cob14-admin@teste.invalido","role":"authenticated"}';

\echo '-- admin cobra — deve PASSAR'
select (admin_disparar_cobranca(:'part'::uuid,'contrato_assinado','Assine o contrato','Corpo') ->> 'enfileiradas')::int = 1 as enfileirou_ok;
select ultima_cobranca_em is not null as lista_mostra_cobranca_ok
from admin_pendencias_lista('cob14','contrato_assinado') where sujeito_id=:'part'::uuid;
\echo '-- cobrar de novo dentro de 3 dias e bloqueado (nao enfileira) — deve PASSAR'
select (admin_disparar_cobranca(:'part'::uuid,'contrato_assinado','De novo','Corpo') ->> 'bloqueadas')::int = 1 as bloqueou_ok;

set request.jwt.claims = '{"email":"cob14-staff@teste.invalido","role":"authenticated"}';
savepoint s_cob_staff;
\echo '-- staff nao dispara cobranca — deve FALHAR'
select admin_disparar_cobranca(:'part'::uuid,'contrato_assinado','x','x');
rollback to s_cob_staff;

reset role;
reset request.jwt.claims;
select id as notif from notificacoes where sujeito_id=:'part'::uuid and tipo='cobranca_contrato_assinado' \gset
-- o CIO assina entre o "preparar" e o "enviar a fila"
insert into contratos (participante_id,status,assinado_em) values (:'part'::uuid,'assinado',now());

set role authenticated;
set request.jwt.claims = '{"email":"cob14-staff@teste.invalido","role":"authenticated"}';
\echo '-- na hora de enviar, a cobranca ja resolvida NAO vai no lote — deve PASSAR'
select count(*) = 0 as fora_do_lote_ok from notificacoes_pendentes(50, :'notif'::uuid);
reset role;
reset request.jwt.claims;
\echo '-- e fica marcada como pulada, com o motivo — deve PASSAR'
select status = 'enviada' and erro like 'Pulado:%' as marcada_pulada_ok from notificacoes where id=:'notif'::uuid;

set role authenticated;
set request.jwt.claims = '{"email":"cob14-admin@teste.invalido","role":"authenticated"}';
savepoint s_cob_concluida;
\echo '-- cobrar etapa ja concluida — deve FALHAR'
select admin_disparar_cobranca(:'part'::uuid,'contrato_assinado','x','x', true);
rollback to s_cob_concluida;

reset role;
reset request.jwt.claims;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
