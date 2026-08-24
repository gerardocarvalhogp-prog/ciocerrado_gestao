-- =====================================================================
-- Cenario de teste ponta a ponta · gestao CIO Cerrado
--
-- Roda contra o banco LOCAL depois de `supabase db reset`.
--
-- Simula o que o PostgREST faz: define request.jwt.claims com o e-mail
-- do usuario e troca o papel para `authenticated`. E assim que auth.jwt()
-- enxerga quem esta chamando — sem isso, todo teste rodaria como
-- superusuario e passaria por engano.
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

\echo '#############################################'
\echo '# SETUP  (como postgres, direto nas tabelas)'
\echo '#############################################'

update eventos set status='aberto', data_inicio='2027-08-11', data_fim='2027-08-15',
       prazo_contrato='2027-07-01', prazo_rooming='2027-07-20'
 where slug='cerrado2027';

-- precos: acompanhante 800, crianca 400, transfer 150, duplo extra 1200
update precos set valor=800  where item='acompanhante_adulto';
update precos set valor=400  where item='crianca';
update precos set valor=150  where item='transfer';
update precos set valor=1200 where item='quarto_duplo';

-- composicao das cotas (tabela cota_quartos, da migracao-02)
insert into cota_quartos (cota_id, tipo, quantidade)
select c.id, 'duplo', 2 from cotas c join eventos e on e.id=c.evento_id
 where e.slug='cerrado2027' and c.nome='Esmeralda'
on conflict (cota_id, tipo) do update set quantidade=excluded.quantidade;

insert into cota_quartos (cota_id, tipo, quantidade)
select c.id, 'duplo', 1 from cotas c join eventos e on e.id=c.evento_id
 where e.slug='cerrado2027' and c.nome='Ouro'
on conflict (cota_id, tipo) do update set quantidade=excluded.quantidade;

-- duas patrocinadoras em cotas diferentes
insert into patrocinadores (evento_id, cota_id, empresa, segmento, o_que_vende, natureza)
select e.id, c.id, 'Alfa Cloud', 'Tecnologia', 'Cloud, FinOps e migracao', 'privada'
from eventos e join cotas c on c.evento_id=e.id
where e.slug='cerrado2027' and c.nome='Esmeralda'
on conflict do nothing;

insert into patrocinadores (evento_id, cota_id, empresa, segmento, o_que_vende, natureza)
select e.id, c.id, 'Beta Seguranca', 'Seguranca', 'SOC e resposta a incidente', 'privada'
from eventos e join cotas c on c.evento_id=e.id
where e.slug='cerrado2027' and c.nome='Ouro'
on conflict do nothing;

-- um usuario para cada
insert into usuarios_patrocinador (patrocinador_id, email, nome)
select p.id, 'ana@alfa.test', 'Ana' from patrocinadores p where p.empresa='Alfa Cloud'
on conflict do nothing;

insert into usuarios_patrocinador (patrocinador_id, email, nome)
select p.id, 'bruno@beta.test', 'Bruno' from patrocinadores p where p.empresa='Beta Seguranca'
on conflict do nothing;

-- inventario de quartos
insert into quartos (evento_id, numero, tipo, capacidade, status)
select e.id, n::text, 'duplo', 2, 'disponivel'
from eventos e, generate_series(201,206) n
where e.slug='cerrado2027'
on conflict do nothing;

-- um CIO aprovado com contrato assinado, para o fluxo do participante
insert into gestores (nome, email, empresa, cargo, segmento)
values ('Carlos Diretor','carlos@cliente.test','Varejo XPTO','CIO','Varejo')
on conflict (email_norm) do nothing;

insert into participantes (evento_id, gestor_id, status, origem, aprovado_em)
select e.id, g.id, 'aprovado', 'manual', now()
from eventos e, gestores g
where e.slug='cerrado2027' and g.email_norm=norm_doc('carlos@cliente.test')
on conflict do nothing;

insert into contratos (participante_id, status, assinado_em)
select pa.id, 'assinado', now()
from participantes pa join gestores g on g.id=pa.gestor_id
where g.email_norm=norm_doc('carlos@cliente.test')
on conflict (participante_id) do update set status='assinado', assinado_em=now();

\echo ''
\echo '=== gerar quartos das cotas (como admin) ==='
set role authenticated;
set request.jwt.claims = '{"email":"gerardocarvalhogp@gmail.com","role":"authenticated"}';
select admin_gerar_quartos_todos('cerrado2027');
reset role;

\echo ''
\echo '#############################################'
\echo '# TESTE 1 · Ana (Alfa Cloud) ve so a Alfa'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"ana@alfa.test","role":"authenticated"}';

\echo '-- painel dela:'
select empresa, cota, quartos_total, quartos_preenchidos from patro_meu_painel('cerrado2027');

\echo '-- quartos dela:'
select rotulo, tipo, capacidade, ocupantes, status, origem
from patro_listar_quartos((select id from patrocinadores where empresa='Alfa Cloud'));

\echo ''
\echo '=== TESTE 2 · Ana tenta ler os quartos da Beta (deve FALHAR) ==='
select rotulo from patro_listar_quartos((select id from patrocinadores where empresa='Beta Seguranca'));

\echo ''
\echo '=== TESTE 3 · Ana tenta funcao de admin (deve FALHAR) ==='
select * from admin_listar_equipe();

\echo ''
\echo '=== TESTE 4 · Ana preenche um quarto ==='
select patro_salvar_quarto(
  (select id from reservas r join patrocinadores p on p.id=r.patrocinador_id
    where p.empresa='Alfa Cloud' order by r.created_at limit 1),
  '[{"nome":"Ana Souza","cpf":"11122233344","tipo":"adulto","usa_transfer":true},
    {"nome":"Rui Lima","cpf":"55566677788","tipo":"adulto","usa_transfer":false}]'::jsonb,
  true, 'GYN', true, 'Kit cafe'
);

\echo '-- o quarto virou completo e o brinde entrou?'
select rotulo, status, ocupantes, usa_transfer, transfer_origem, brinde_vai_enviar, brinde_descricao
from patro_listar_quartos((select id from patrocinadores where empresa='Alfa Cloud'));

\echo ''
\echo '=== TESTE 5 · Ana compra quarto extra e a fatura recalcula ==='
select patro_comprar_quarto((select id from patrocinadores where empresa='Alfa Cloud'), 'duplo');
reset role;

\echo '-- fatura da Alfa (1 quarto extra 1200 + 1 transfer 150):'
select f.total, fi.descricao, fi.quantidade, fi.valor_unit
from faturas f join fatura_itens fi on fi.fatura_id=f.id
join patrocinadores p on p.id=f.patrocinador_id
where p.empresa='Alfa Cloud' order by fi.descricao;

\echo ''
\echo '#############################################'
\echo '# TESTE 6 · Bruno (Beta) nao ve nada da Alfa'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"bruno@beta.test","role":"authenticated"}';
\echo '-- painel do Bruno:'
select empresa, cota, quartos_total from patro_meu_painel('cerrado2027');
\echo '-- Bruno tenta salvar no quarto da Alfa (deve FALHAR):'
select patro_salvar_quarto(
  (select r.id from reservas r join patrocinadores p on p.id=r.patrocinador_id
    where p.empresa='Alfa Cloud' order by r.created_at limit 1),
  '[{"nome":"Invasor","tipo":"adulto"}]'::jsonb, false, null, false, null);
reset role;

\echo ''
\echo '#############################################'
\echo '# TESTE 7 · Fluxo do participante (Carlos)'
\echo '#############################################'
set role authenticated;
set request.jwt.claims = '{"email":"carlos@cliente.test","role":"authenticated"}';

\echo '-- status (rooming_liberado deve ser true: aprovado + assinado):'
select part_meu_status('cerrado2027') -> 'rooming_liberado' as rooming_liberado,
       part_meu_status('cerrado2027') -> 'status_contrato'  as contrato;

\echo '-- previa da fatura: 1 acompanhante adulto + 1 crianca + 2 transfers'
select part_previa_fatura('cerrado2027',
  '[{"nome":"Maria","tipo":"adulto","data_nascimento":"1985-03-02","usa_transfer":true},
    {"nome":"Joao","tipo":"crianca","data_nascimento":"2020-05-10","usa_transfer":false}]'::jsonb,
  true);

\echo '-- salva o rooming:'
select part_salvar_rooming('cerrado2027',
  '[{"nome":"Maria","tipo":"adulto","data_nascimento":"1985-03-02","usa_transfer":true},
    {"nome":"Joao","tipo":"crianca","data_nascimento":"2020-05-10","usa_transfer":false}]'::jsonb,
  true, 'BSB');

\echo '-- ocupantes gravados (titular deve ter sido criado sozinho):'
select nome, tipo, usa_transfer from part_listar_rooming('cerrado2027');
reset role;

\echo '-- fatura do Carlos:'
select f.total, fi.descricao, fi.valor_unit
from faturas f join fatura_itens fi on fi.fatura_id=f.id
join participantes pa on pa.id=f.participante_id
join gestores g on g.id=pa.gestor_id
where g.email_norm=norm_doc('carlos@cliente.test') order by fi.descricao;

\echo ''
\echo '#############################################'
\echo '# TESTE 8 · anon nao passa'
\echo '#############################################'
set role anon;
set request.jwt.claims = '{"role":"anon"}';
\echo '-- anon tenta listar equipe (deve FALHAR por permissao):'
select * from admin_listar_equipe();
\echo '-- anon tenta o painel do patrocinador (deve FALHAR):'
select * from patro_meu_painel('cerrado2027');
\echo '-- anon PODE se auto-cadastrar (unica liberada):'
select part_autocadastro('cerrado2027','Novo CIO','novo@cliente.test','Empresa Nova');
reset role;
reset request.jwt.claims;
