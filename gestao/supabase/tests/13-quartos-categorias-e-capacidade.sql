-- =====================================================================
-- Quartos: finalidade, pool avulso, bloqueio, capacidade fixa do
-- patrocinador, "ocupado por" e etiqueta de equipe · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM — mesmo padrao de 07 e 12.
-- Nao depende de dado nenhum do banco: cria o proprio evento ('cob13'),
-- os proprios admins/staff, a cota, o patrocinador e o CIO.
--
-- COBRE (migrations sem teste ate 05/10/2026):
--
--   1. admin_listar_quartos_individual e admin_editar_tipo_quarto
--      (20260901130000, recriadas em 20260909120000/20260930140000)
--   2. admin_definir_status_quarto: bloquear pra venda avulsa
--      (20260930110000)
--   3. quartos.finalidade e a trava em admin_alocar_quarto
--      (20260930130000/20260930140000) — substitui o publico_alvo de
--      20260902130000, removido em 20260909120000
--   4. compra automatica (patrocinador e CIO) so pesca do pool avulso
--      (20260930140000)
--   5. capacidade fixa por tipo pro patrocinador (20260930100000)
--   6. reservas.ocupado_por (20260909120000)
--   7. _garantir_reserva nao duplica (20260918090000) — so a parte
--      sequencial; a corrida de verdade precisaria de duas conexoes
--   8. etiqueta de quarto de equipe leva o rotulo como empresa
--      (20261001240000)
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO
-- ---------------------------------------------------------------------
insert into eventos (slug,nome,status,data_inicio,data_fim)
values ('cob13','Cobertura 13','aberto','2027-08-12','2027-08-16');
select id as ev from eventos where slug='cob13' \gset

insert into admins (email,nome,role) values
  ('cob13-admin@teste.invalido','Admin Cob13','admin'),
  ('cob13-staff@teste.invalido','Staff Cob13','staff'),
  ('cob13-fora@teste.invalido','Staff de outro evento','staff');
insert into admin_eventos (admin_id,evento_id)
select id, :'ev'::uuid from admins where email='cob13-staff@teste.invalido';

insert into cotas (evento_id,nome,ordem_prioridade,quartos_incluidos)
values (:'ev'::uuid,'Ouro Cob13',1,0);
select id as cota from cotas where evento_id=:'ev'::uuid \gset

insert into patrocinadores (evento_id,cota_id,empresa,status)
values (:'ev'::uuid,:'cota'::uuid,'Patro Cob13','ativo');
select id as pat from patrocinadores where empresa='Patro Cob13' and evento_id=:'ev'::uuid \gset
insert into usuarios_patrocinador (patrocinador_id,email,nome)
values (:'pat'::uuid,'patro13@teste.invalido','Usuario Patro13');

insert into gestores (nome,email,empresa,cargo)
values ('CIO Cob Treze','cio13@teste.invalido','Industria Treze','CIO'),
       ('CIO Cob Treze B','cio13b@teste.invalido','Varejo Treze','CIO')
on conflict (email_norm) do nothing;
insert into participantes (evento_id,gestor_id,status,origem,aprovado_em)
select :'ev'::uuid, id, 'aprovado','manual',now() from gestores
 where email in ('cio13@teste.invalido','cio13b@teste.invalido');
select pa.id as part from participantes pa join gestores g on g.id=pa.gestor_id
 where g.email='cio13@teste.invalido' and pa.evento_id=:'ev'::uuid \gset

set role authenticated;
set request.jwt.claims = '{"email":"cob13-admin@teste.invalido","role":"authenticated"}';
-- numeros de 3 digitos de proposito: ver o ACHADO logo abaixo
select (admin_criar_faixa_quartos('cob13', 301, 306, 'duplo', 'B13') ->> 'criados')::int = 6 as criou_seis_ok;

savepoint s_achado_lpad;
\echo '-- ACHADO (05/10/2026): faixa com numero de 4 digitos. admin_criar_faixa_quartos'
\echo '-- faz lpad(numero, 3) — que no Postgres TRUNCA o que passa de 3: 1301..1306'
\echo '-- viram todos "130", so o primeiro entra e a funcao devolve criados=1 sem'
\echo '-- erro. Vem do baseline (24/08), nao de migration nova. Esperado: 6 quartos.'
select admin_criar_faixa_quartos('cob13', 1301, 1306, 'duplo', 'B13') ->> 'criados' as criados_de_6;
select array_agg(numero order by numero) as numeros_gravados
from admin_listar_quartos_individual('cob13','130');
rollback to s_achado_lpad;
reset role;
reset request.jwt.claims;

select id as q1 from quartos where evento_id=:'ev'::uuid and numero='301' \gset
select id as q2 from quartos where evento_id=:'ev'::uuid and numero='302' \gset
select id as q3 from quartos where evento_id=:'ev'::uuid and numero='303' \gset
select id as q4 from quartos where evento_id=:'ev'::uuid and numero='304' \gset

-- reserva do CIO (a da inscricao) e um quarto de equipe
select _garantir_reserva(:'part'::uuid) as res_cio \gset
insert into ocupantes (reserva_id,nome,tipo) values (:'res_cio'::uuid,'CIO Cob Treze','titular');
insert into reservas (evento_id,rotulo,tipo,origem,status)
values (:'ev'::uuid,'Seguranca Cob13','duplo','equipe','rascunho');
select id as res_eq from reservas where evento_id=:'ev'::uuid and origem='equipe' \gset
insert into ocupantes (reserva_id,nome,tipo) values (:'res_eq'::uuid,'Vigia Cob13','adulto');

\echo ''
\echo '#############################################'
\echo '# 1 · LISTAR UM POR UM E EDITAR O TIPO'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cob13-staff@teste.invalido","role":"authenticated"}';
\echo '-- staff do evento lista os 6 quartos, todos com finalidade avulso — deve PASSAR'
select count(*) = 6 and bool_and(finalidade = 'avulso') as seis_avulsos_ok
from admin_listar_quartos_individual('cob13');
\echo '-- a busca filtra por numero — deve PASSAR'
select array_agg(numero) = array['303'] as busca_ok
from admin_listar_quartos_individual('cob13', '303');

savepoint s_tipo_staff;
\echo '-- staff (nao admin) tenta mudar o tipo de um quarto — deve FALHAR'
select admin_editar_tipo_quarto(:'q1'::uuid, 'single');
rollback to s_tipo_staff;

set request.jwt.claims = '{"email":"cob13-admin@teste.invalido","role":"authenticated"}';
\echo '-- admin troca 301 pra quadruplo — deve PASSAR'
select admin_editar_tipo_quarto(:'q1'::uuid, 'quadruplo') ->> 'ok' = 'true' as editou_ok;
savepoint s_tipo_inv;
\echo '-- tipo inexistente — deve FALHAR'
select admin_editar_tipo_quarto(:'q1'::uuid, 'suite');
rollback to s_tipo_inv;
\echo '-- a capacidade acompanhou o tipo (quadruplo = 4) — deve PASSAR'
select capacidade = 4 as capacidade_ok
from admin_listar_quartos_individual('cob13', '301');

\echo ''
\echo '#############################################'
\echo '# 2 · BLOQUEAR QUARTO (VENDA AVULSA PELO RESORT)'
\echo '#############################################'
set request.jwt.claims = '{"email":"cob13-staff@teste.invalido","role":"authenticated"}';
\echo '-- staff bloqueia o 306 — deve PASSAR'
select admin_definir_status_quarto(
  (select id from admin_listar_quartos_individual('cob13','306')), 'bloqueado') ->> 'ok' = 'true' as bloqueou_ok;
\echo '-- quarto bloqueado some dos livres pra atribuir — deve PASSAR'
select not exists (select 1 from admin_quartos_livres('cob13') where numero='306') as sumiu_dos_livres_ok;
set request.jwt.claims = '{"email":"cob13-fora@teste.invalido","role":"authenticated"}';
savepoint s_achado_escopo;
\echo '-- ACHADO (05/10/2026): staff de OUTRO evento (sem admin_eventos pro cob13)'
\echo '-- lista os quartos e bloqueia/desbloqueia quarto do cob13. As duas funcoes'
\echo '-- (admin_listar_quartos_individual, admin_definir_status_quarto) checam so'
\echo '-- _exige_staff(), nao o escopo por evento de 10/11. Esperado pelo padrao: recusar.'
select count(*) as quartos_que_o_staff_de_fora_ve from admin_listar_quartos_individual('cob13');
select admin_definir_status_quarto(:'q2'::uuid, 'bloqueado') ->> 'ok' = 'true' as staff_de_fora_bloqueou;
rollback to s_achado_escopo;
set request.jwt.claims = '{"email":"cob13-staff@teste.invalido","role":"authenticated"}';

savepoint s_status_inv;
\echo '-- "reservado" nao se escreve na mao, e automatico — deve FALHAR'
select admin_definir_status_quarto(:'q2'::uuid, 'reservado');
rollback to s_status_inv;

\echo ''
\echo '#############################################'
\echo '# 3 · FINALIDADE DO QUARTO TRAVA A ALOCACAO'
\echo '#############################################'
savepoint s_fin_staff;
\echo '-- staff tenta definir finalidade — so admin pode — deve FALHAR'
select admin_definir_finalidade_quarto(:'q2'::uuid, 'cio');
rollback to s_fin_staff;

set request.jwt.claims = '{"email":"cob13-admin@teste.invalido","role":"authenticated"}';
savepoint s_fin_inv;
\echo '-- finalidade fora da lista — deve FALHAR'
select admin_definir_finalidade_quarto(:'q2'::uuid, 'vip');
rollback to s_fin_inv;

\echo '-- 302 vira patrocinador, 303 vira cio, 304 vira staff — deve PASSAR'
select admin_definir_finalidade_quarto(:'q2'::uuid, 'patrocinador') ->> 'ok' = 'true' as p_ok,
       admin_definir_finalidade_quarto(:'q3'::uuid, 'cio')          ->> 'ok' = 'true' as c_ok,
       admin_definir_finalidade_quarto(:'q4'::uuid, 'staff')        ->> 'ok' = 'true' as s_ok;

\echo '-- reserva de CIO em quarto de patrocinador: recusa com motivo — deve PASSAR'
select admin_alocar_quarto(:'res_cio'::uuid, :'q2'::uuid) ->> 'motivo' = 'finalidade_incompativel' as recusou_ok;
\echo '-- reserva de equipe em quarto de CIO: recusa com motivo — deve PASSAR'
select admin_alocar_quarto(:'res_eq'::uuid, :'q3'::uuid) ->> 'motivo' = 'finalidade_incompativel' as recusou_equipe_ok;
\echo '-- reserva de CIO em quarto de CIO — deve PASSAR'
select admin_alocar_quarto(:'res_cio'::uuid, :'q3'::uuid) ->> 'ok' = 'true' as cio_alocado_ok;
\echo '-- reserva de equipe em quarto de staff (equipe aceita staff e organizacao) — deve PASSAR'
select admin_alocar_quarto(:'res_eq'::uuid, :'q4'::uuid) ->> 'ok' = 'true' as equipe_alocada_ok;

savepoint s_fin_ocupado;
\echo '-- 303 tem CIO dentro: virar patrocinador — deve FALHAR'
select admin_definir_finalidade_quarto(:'q3'::uuid, 'patrocinador');
rollback to s_fin_ocupado;
\echo '-- 304 tem equipe dentro: virar organizacao continua aceitando a equipe — deve PASSAR'
select admin_definir_finalidade_quarto(:'q4'::uuid, 'organizacao') ->> 'ok' = 'true' as org_ok;

\echo '-- faixa 301..305 pra patrocinador pula o 303 (CIO dentro) e o'
\echo '-- 304 (equipe dentro); o 302 ja era patrocinador: altera so 301 e 305 — deve PASSAR'
select (admin_definir_finalidade_faixa('cob13','301','305','patrocinador') ->> 'alterados')::int = 2 as faixa_ok;

savepoint s_bloq_ocupado;
\echo '-- quarto com reserva nao se bloqueia (libera antes) — deve FALHAR'
select admin_definir_status_quarto(:'q3'::uuid, 'bloqueado');
rollback to s_bloq_ocupado;

\echo ''
\echo '#############################################'
\echo '# 4 · COMPRA AUTOMATICA SO PESCA DO POOL AVULSO'
\echo '#############################################'
-- neste ponto: 301/302/305 patrocinador, 303 cio (ocupado),
-- 304 organizacao (ocupado), 306 avulso mas bloqueado. Nada avulso livre.
set request.jwt.claims = '{"email":"patro13@teste.invalido","role":"authenticated"}';
\echo '-- patrocinador compra duplo sem nenhum avulso livre: sem_disponibilidade — deve PASSAR'
select patro_comprar_quarto(:'pat'::uuid, 'duplo') ->> 'motivo' = 'sem_disponibilidade' as patro_sem_vaga_ok;
set request.jwt.claims = '{"email":"cio13@teste.invalido","role":"authenticated"}';
\echo '-- CIO idem — deve PASSAR'
select part_comprar_quarto('cob13', 'duplo') ->> 'motivo' = 'sem_disponibilidade' as cio_sem_vaga_ok;
\echo '-- disponibilidade mostrada ao CIO: zero livres de duplo — deve PASSAR'
select coalesce((select livres from part_disponibilidade('cob13') where tipo='duplo'), 0) = 0 as zero_livres_ok;

set request.jwt.claims = '{"email":"cob13-staff@teste.invalido","role":"authenticated"}';
select admin_definir_status_quarto(
  (select id from admin_listar_quartos_individual('cob13','306')), 'disponivel') ->> 'ok' as desbloqueou;

set request.jwt.claims = '{"email":"cio13@teste.invalido","role":"authenticated"}';
\echo '-- 306 (avulso) desbloqueado: aparece 1 livre pro CIO — deve PASSAR'
select (select livres from part_disponibilidade('cob13') where tipo='duplo') = 1 as um_livre_ok;

savepoint s_achado_extra;
\echo '-- ACHADO (05/10/2026): CIO que JA TEM a reserva principal tenta comprar'
\echo '-- quarto extra. 20260930140000 diz que isso volta a existir, mas o'
\echo '-- indice unico reservas_participante_ativa_uk (20260918090000, de quando'
\echo '-- o CIO nao comprava extra) so deixa UMA reserva ativa por participante.'
\echo '-- Hoje estoura com duplicate key. Decisao do organizador — ver LEIA-ME.'
select part_comprar_quarto('cob13', 'duplo');
rollback to s_achado_extra;

-- a regra do pool em si se prova com um CIO que ainda nao tem reserva
-- nenhuma (rooming nao preenchido) — ai o indice nao atrapalha
set request.jwt.claims = '{"email":"cio13b@teste.invalido","role":"authenticated"}';
\echo '-- CIO sem reserva compra e leva exatamente o 306 (o unico avulso) — deve PASSAR'
select part_comprar_quarto('cob13', 'duplo') ->> 'ok' = 'true' as cio_comprou_ok;
select quarto_numero = '306' as levou_o_avulso_ok
from part_listar_meus_quartos('cob13') where origem='extra';
\echo '-- e cancelar devolve o 306 pro pool — deve PASSAR'
select part_cancelar_quarto_extra((select reserva_id from part_listar_meus_quartos('cob13') where origem='extra')) ->> 'ok' = 'true' as cancelou_ok;
select (select livres from part_disponibilidade('cob13') where tipo='duplo') = 1 as voltou_pro_pool_ok;

\echo ''
\echo '#############################################'
\echo '# 5 · CAPACIDADE FIXA POR TIPO PRO PATROCINADOR'
\echo '#############################################'
reset role;
reset request.jwt.claims;
insert into reservas (evento_id,patrocinador_id,rotulo,tipo,origem,status)
values (:'ev'::uuid,:'pat'::uuid,'Quarto 1','duplo','cota','rascunho');
select id as res_pat from reservas where patrocinador_id=:'pat'::uuid \gset
set role authenticated;
set request.jwt.claims = '{"email":"patro13@teste.invalido","role":"authenticated"}';
\echo '-- a tela do patrocinador mostra duplo = 2 (nao o teto 4 do CIO) — deve PASSAR'
select capacidade = 2 as mostra_dois_ok from patro_listar_quartos(:'pat'::uuid) where reserva_id=:'res_pat'::uuid;
savepoint s_cap;
\echo '-- 3 pessoas num duplo do patrocinador — deve FALHAR'
select patro_salvar_quarto(:'res_pat'::uuid,
  '[{"nome":"Um"},{"nome":"Dois"},{"nome":"Tres"}]'::jsonb);
rollback to s_cap;
\echo '-- 2 pessoas no duplo — deve PASSAR'
select patro_salvar_quarto(:'res_pat'::uuid, '[{"nome":"Um"},{"nome":"Dois"}]'::jsonb) ->> 'ok' = 'true' as dois_ok;

\echo ''
\echo '#############################################'
\echo '# 6 · "OCUPADO POR" DIGITADO PELO STAFF'
\echo '#############################################'
set request.jwt.claims = '{"email":"cob13-fora@teste.invalido","role":"authenticated"}';
savepoint s_ocup_fora;
\echo '-- staff de outro evento tenta escrever "ocupado por" — deve FALHAR'
select admin_definir_ocupado_por(:'res_cio'::uuid, 'Intruso');
rollback to s_ocup_fora;
set request.jwt.claims = '{"email":"cob13-staff@teste.invalido","role":"authenticated"}';
\echo '-- staff do evento escreve — deve PASSAR'
select admin_definir_ocupado_por(:'res_cio'::uuid, '  Fulano / Industria Treze  ') ->> 'ok' = 'true' as escreveu_ok;
\echo '-- o texto (aparado) vence o derivado na lista de quartos e na alocacao — deve PASSAR'
select ocupado_por = 'Fulano / Industria Treze' as lista_ok from admin_listar_quartos_individual('cob13','303');
select bool_and(empresa = 'Fulano / Industria Treze') as alocacao_ok
from admin_listar_alocacao('cob13') where reserva_id=:'res_cio'::uuid;
\echo '-- texto vazio volta pro derivado (empresa do CIO, que o cadastro'
\echo '-- padroniza em maiusculas desde 20260831170000) — deve PASSAR'
select admin_definir_ocupado_por(:'res_cio'::uuid, '   ') ->> 'ok' as limpou;
select ocupado_por ilike 'industria treze' as voltou_ok from admin_listar_quartos_individual('cob13','303');

\echo ''
\echo '#############################################'
\echo '# 7 · _garantir_reserva NAO DUPLICA'
\echo '#############################################'
reset role;
reset request.jwt.claims;
\echo '-- chamar de novo devolve a MESMA reserva — deve PASSAR'
select _garantir_reserva(:'part'::uuid) = :'res_cio'::uuid as mesma_ok;
select count(*) = 1 as uma_so_ok from reservas
 where participante_id=:'part'::uuid and origem <> 'extra' and status <> 'cancelado';

\echo ''
\echo '#############################################'
\echo '# 8 · ETIQUETA DE QUARTO DE EQUIPE'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cob13-staff@teste.invalido","role":"authenticated"}';
\echo '-- ocupante de quarto de equipe sai com o rotulo no campo EMPRESA — deve PASSAR'
select empresa = 'Seguranca Cob13' and apto = '304' as etiqueta_ok
from admin_etiquetas('cob13') where nome ilike 'vigia cob13';

reset role;
reset request.jwt.claims;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
