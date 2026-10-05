-- =====================================================================
-- Cadastro de gestores e empresas: padrao de formatacao, editar,
-- filtros, enriquecimento, empresa global entre eventos e CPF/CNPJ
-- como chave · gestao CIO Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM — mesmo padrao de 07 e 12.
-- Gestores e empresas sao tabelas globais; tudo aqui tem "Cob21" no
-- nome ou @teste.invalido no e-mail. Cria os proprios eventos.
--
-- COBRE (migrations sem teste ate 05/10/2026):
--
--   1. trigger de padrao de cadastro: caixa alta, "0" vira nulo, UF por
--      extenso vira sigla, sigla estrangeira fica, segmento normalizado
--      (20260831170000)
--   2. admin_editar_gestor (20260901090000) e admin_filtros_gestores,
--      que nunca tinha funcionado (20260901100000)
--   3. enriquecimento "IA ajusta/popula": o que vem preenchido
--      sobrescreve, o que vem vazio nao apaga — gestor (20260902200000)
--      e patrocinador com CNPJ, gravando tambem na empresa
--      (20260901120000)
--   4. patrocinador como vinculo de uma EMPRESA global: mesma empresa
--      em dois eventos, login reaproveitado, listagem lendo da empresa
--      (20260909100000, 20260929100000), filtro so patrocinadoras
--      (20260929180000)
--   5. CPF como chave na importacao do Sympla (20261001120000) e CNPJ
--      como chave de empresa (20261001130000)
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO
-- ---------------------------------------------------------------------
insert into eventos (slug,nome,status) values
  ('cob21a','Cobertura 21 A','aberto'),
  ('cob21b','Cobertura 21 B','aberto');
insert into cotas (evento_id,nome,ordem_prioridade)
select id,'Ouro Cob21',1 from eventos where slug in ('cob21a','cob21b');

insert into admins (email,nome,role) values
  ('cob21-admin@teste.invalido','Admin Cob21','admin'),
  ('cob21-staff@teste.invalido','Staff Cob21','staff');

\echo ''
\echo '#############################################'
\echo '# 1 · PADRAO DE CADASTRO (TRIGGER)'
\echo '#############################################'
insert into gestores (nome,email,empresa,cargo,cidade,estado,segmento) values
  ('  joão   da  silva cob21 ','joao21@teste.invalido','0','  diretor de ti ','goiânia','Goiás','10 - Saúde'),
  ('Silvio Cob21','silvio21@teste.invalido','Emp Silvio','CIO','San Jose','CA','TECNOLOGIA'),
  ('Lixo Cob21','lixo21@teste.invalido','Emp Lixo','CIO',null,'Estado Nenhum','Industria Farmaceutica');
\echo '-- caixa alta, espaco colapsado, "0" vira nulo, UF por extenso vira sigla, segmento da lista — deve PASSAR'
select nome = 'JOÃO DA SILVA COB21' and empresa is null and cargo = 'DIRETOR DE TI'
       and cidade = 'GOIÂNIA' and estado = 'GO' and segmento = 'SAÚDE' as joao_ok
from gestores where email='joao21@teste.invalido';
\echo '-- sigla estrangeira (CA) fica; TECNOLOGIA (area, nao segmento) vira nulo — deve PASSAR'
select estado = 'CA' and segmento is null as silvio_ok from gestores where email='silvio21@teste.invalido';
\echo '-- estado que nao e UF nem sigla vira nulo; variacao conhecida casa com a lista — deve PASSAR'
select estado is null and segmento = 'INDÚSTRIA' as lixo_ok from gestores where email='lixo21@teste.invalido';
insert into empresas (nome,cidade,estado) values ('  empresa   cob21 ltda ','brasília','distrito federal');
\echo '-- empresas seguem o mesmo padrao — deve PASSAR'
select nome = 'EMPRESA COB21 LTDA' and cidade = 'BRASÍLIA' and estado = 'DF' as empresa_ok
from empresas where nome ilike '%empresa cob21%';

select id as g_joao from gestores where email='joao21@teste.invalido' \gset

\echo ''
\echo '#############################################'
\echo '# 2 · EDITAR GESTOR E FILTROS'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cob21-staff@teste.invalido","role":"authenticated"}';
savepoint s_editar_staff;
\echo '-- staff edita gestor — so admin — deve FALHAR'
select admin_editar_gestor(:'g_joao'::uuid, 'X');
rollback to s_editar_staff;

set request.jwt.claims = '{"email":"cob21-admin@teste.invalido","role":"authenticated"}';
savepoint s_editar_sem_nome;
\echo '-- editar sem nome — deve FALHAR'
select admin_editar_gestor(:'g_joao'::uuid, '  ');
rollback to s_editar_sem_nome;
savepoint s_editar_inexistente;
\echo '-- editar gestor que nao existe — deve FALHAR'
select admin_editar_gestor(gen_random_uuid(), 'Ninguem');
rollback to s_editar_inexistente;
\echo '-- admin corrige empresa, cidade e UF (o padrao de cadastro vale aqui tambem) — deve PASSAR'
select admin_editar_gestor(:'g_joao'::uuid, 'Joao da Silva Cob21', 'joao21@teste.invalido', 'CTO', null,
                           'Industria Joao Cob21', 'Saude', 'Anapolis', 'goias', 'CIO') ->> 'ok' = 'true' as editou_ok;
reset role;
reset request.jwt.claims;
select nome = 'JOAO DA SILVA COB21' and empresa = 'INDUSTRIA JOAO COB21' and estado = 'GO'
       and segmento = 'SAÚDE' and perfil = 'CIO' and telefone is null as editado_ok
from gestores where id=:'g_joao'::uuid;

set role authenticated;
set request.jwt.claims = '{"email":"cob21-admin@teste.invalido","role":"authenticated"}';
\echo '-- admin_filtros_gestores roda (antes: coluna "v" ambigua) e traz a cidade nova — deve PASSAR'
select f ? 'perfis' and f ? 'segmentos' and f ? 'estados' and f ? 'posicoes'
       and f -> 'cidades' @> '[{"v":"ANAPOLIS"}]' as filtros_ok
from admin_filtros_gestores() f;

\echo ''
\echo '#############################################'
\echo '# 3 · ENRIQUECIMENTO: AJUSTA O QUE VEM, NAO APAGA O QUE NAO VEM'
\echo '#############################################'
\echo '-- "IA" ajusta o cargo e popula o linkedin; empresa vem em branco e nao apaga — deve PASSAR'
select admin_enriquecer_gestor(:'g_joao'::uuid, p_cargo => 'CTO e CDO', p_empresa => '  ', p_linkedin => 'linkedin.test/joao21') ->> 'ok' as enriqueceu;
reset role;
reset request.jwt.claims;
select cargo = 'CTO E CDO' and empresa = 'INDUSTRIA JOAO COB21' and linkedin = 'linkedin.test/joao21' as enriquecido_ok
from gestores where id=:'g_joao'::uuid;

\echo ''
\echo '#############################################'
\echo '# 4 · EMPRESA GLOBAL, VINCULO POR EVENTO'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"cob21-admin@teste.invalido","role":"authenticated"}';
\echo '-- a mesma empresa patrocina os dois eventos: um cadastro de empresa so — deve PASSAR'
select admin_salvar_patrocinador('cob21a','Alfa Cob21','Ouro Cob21', p_site => 'https://alfa21.test') as r_a \gset
select admin_salvar_patrocinador('cob21b','alfa cob21','Ouro Cob21') as r_b \gset
select (:'r_a'::jsonb ->> 'empresa_id') = (:'r_b'::jsonb ->> 'empresa_id')
   and (:'r_a'::jsonb ->> 'id') <> (:'r_b'::jsonb ->> 'id') as mesma_empresa_ok;
select (:'r_a'::jsonb ->> 'empresa_id') as emp_alfa, (:'r_a'::jsonb ->> 'id') as pat_a, (:'r_b'::jsonb ->> 'id') as pat_b \gset

\echo '-- o login e da EMPRESA: cadastrado uma vez, enxerga o vinculo dos dois eventos — deve PASSAR'
select admin_salvar_usuario_patro(:'emp_alfa'::uuid, ' Contato@Alfa21.TEST ', 'Contato Alfa') ->> 'ok' as usuario;
select count(*) = 1 and bool_and(email = 'contato@alfa21.test') as usuario_ok from admin_listar_usuarios_patro(:'emp_alfa'::uuid);
set request.jwt.claims = '{"email":"contato@alfa21.test","role":"authenticated"}';
select count(*) = 2 and bool_and(id in (:'pat_a'::uuid, :'pat_b'::uuid)) as ve_os_dois_ok from meus_patrocinadores() id;

set request.jwt.claims = '{"email":"cob21-admin@teste.invalido","role":"authenticated"}';
\echo '-- enriquecer com CNPJ grava no vinculo E na empresa (o site sugerido ajusta o antigo) — deve PASSAR'
select admin_enriquecer_patrocinador(:'pat_a'::uuid, p_site => 'https://outro.test', p_cnpj => '11.222.333/0001-81',
                                     p_o_que_vende => 'ERP') ->> 'ok' as enriqueceu_patro;
\echo '-- a listagem do evento B le da empresa: ja ve o CNPJ e o site cadastrados pelo A — deve PASSAR'
select cnpj = '11.222.333/0001-81' and site = 'https://outro.test' and o_que_vende = 'ERP' as listagem_le_empresa_ok
from admin_listar_patrocinadores('cob21b') where id=:'pat_b'::uuid;

\echo '-- CNPJ e a chave: "Grupo Alfa" com o mesmo CNPJ (outra mascara) cai na MESMA empresa — deve PASSAR'
select (admin_salvar_patrocinador('cob21a','Grupo Alfa Cob21', null, '11222333000181') ->> 'empresa_id') = :'emp_alfa' as cnpj_casou_ok;

\echo '-- filtro "so patrocinadoras": empresa de gestor que nunca patrocinou sai — deve PASSAR'
select bool_or(nome ilike 'grupo alfa cob21') and not bool_or(nome ilike 'empresa cob21 ltda') as so_patro_ok
from admin_listar_empresas(p_busca => 'cob21', p_so_patrocinadoras => true);
select bool_or(nome ilike 'empresa cob21 ltda') as sem_filtro_ok
from admin_listar_empresas(p_busca => 'cob21', p_so_patrocinadoras => false);

\echo ''
\echo '#############################################'
\echo '# 5 · CPF E CNPJ COMO CHAVE'
\echo '#############################################'
reset role;
reset request.jwt.claims;
insert into gestores (nome,email,cpf,empresa,cnpj) values
  ('Maria Cob21','maria.corp21@teste.invalido','123.456.789-09','Grupo Y Cob21','44.555.666/0001-99');
insert into empresas (nome,cnpj) values ('Y Comercio Cob21','44555666000199');
select id as g_maria from gestores where email='maria.corp21@teste.invalido' \gset

set role authenticated;
set request.jwt.claims = '{"email":"cob21-admin@teste.invalido","role":"authenticated"}';
\echo '-- Sympla: Maria com e-mail PESSOAL mas o mesmo CPF; depois uma linha sem CPF — deve PASSAR'
select (r ->> 'criados')::int = 2 and (r ->> 'gestores_novos')::int = 1 as importou_ok
from admin_importar_participantes_sympla('cob21a', '[
  {"nome":"Maria","email":"maria.pessoal21@teste.invalido","cpf":"12345678909","estado_pagamento":"aprovado"},
  {"nome":"Novo Cob21","email":"novo21@teste.invalido","estado_pagamento":"aprovado"}
]'::jsonb) r;
reset role;
reset request.jwt.claims;
\echo '-- Maria nao foi duplicada: inscricao no gestor de sempre, e-mail corporativo mantido — deve PASSAR'
select count(*) = 1 as maria_um_gestor_ok from gestores where nome = 'MARIA' or email like 'maria.%21@teste.invalido';
select pa.gestor_id = :'g_maria'::uuid and g.email = 'maria.corp21@teste.invalido' as maria_ok
from participantes pa join gestores g on g.id = pa.gestor_id join eventos e on e.id = pa.evento_id
where e.slug='cob21a' and g.cpf_norm='12345678909';
\echo '-- a linha sem CPF NAO herdou o gestor da linha anterior — deve PASSAR'
select pa.gestor_id <> :'g_maria'::uuid as nao_herdou_ok
from participantes pa join gestores g on g.id=pa.gestor_id where g.email='novo21@teste.invalido';

set role authenticated;
set request.jwt.claims = '{"email":"cob21-admin@teste.invalido","role":"authenticated"}';
\echo '-- vincular empresas: Maria escreveu "Grupo Y" mas o CNPJ e da "Y Comercio" — liga pelo CNPJ — deve PASSAR'
select (admin_vincular_empresas() ->> 'gestores_vinculados_por_cnpj')::int >= 1 as vinculou_ok;
reset role;
reset request.jwt.claims;
select e.nome = 'Y COMERCIO COB21' as ligou_na_certa_ok
from gestores g join empresas e on e.id = g.empresa_id where g.id=:'g_maria'::uuid;
select not exists (select 1 from empresas where nome = 'GRUPO Y COB21') as nao_criou_duplicata_ok;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
