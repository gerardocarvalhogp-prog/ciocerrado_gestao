-- Cenario parte 2 · ids capturados como postgres, para o teste medir a
-- funcao e nao a RLS da tabela.
\set ON_ERROR_STOP off
set search_path = gestao, public;

select id as alfa from patrocinadores where empresa='Alfa Cloud' \gset
select id as beta from patrocinadores where empresa='Beta Seguranca' \gset
select r.id as res1 from reservas r join patrocinadores p on p.id=r.patrocinador_id
 where p.empresa='Alfa Cloud' and r.origem='cota' order by r.created_at limit 1 \gset

\echo '=== 2b · guarda com NULL (como Ana) ==='
set role authenticated;
set request.jwt.claims = '{"email":"ana@alfa.test","role":"authenticated"}';
select 'pode_ver_patrocinador(NULL) = ' || coalesce(pode_ver_patrocinador(null::uuid)::text,'NULL');

\echo ''
\echo '=== 4 · Ana preenche o Quarto 1 ==='
select patro_salvar_quarto(:'res1'::uuid,
  '[{"nome":"Ana Souza","cpf":"11122233344","tipo":"adulto","usa_transfer":true},
    {"nome":"Rui Lima","cpf":"55566677788","tipo":"adulto","usa_transfer":false}]'::jsonb,
  true, 'GYN', true, 'Kit cafe');

\echo '-- estado dos quartos da Alfa:'
select rotulo, status, ocupantes, usa_transfer, transfer_origem,
       brinde_vai_enviar, brinde_descricao
from patro_listar_quartos(:'alfa'::uuid) order by rotulo;

\echo ''
\echo '=== 4b · Ana tenta 3 pessoas num duplo (deve FALHAR) ==='
select patro_salvar_quarto(:'res1'::uuid,
  '[{"nome":"A"},{"nome":"B"},{"nome":"C"}]'::jsonb, false, null, false, null);

\echo ''
\echo '=== 4c · transfer com origem invalida (deve FALHAR) ==='
select patro_salvar_quarto(:'res1'::uuid,
  '[{"nome":"A"}]'::jsonb, true, 'XYZ', false, null);
reset role;

\echo ''
\echo '=== 5 · fatura da Alfa apos preencher + quarto extra ==='
select f.total from faturas f join patrocinadores p on p.id=f.patrocinador_id
where p.empresa='Alfa Cloud';
select fi.descricao, fi.quantidade, fi.valor_unit, fi.valor_total
from faturas f join fatura_itens fi on fi.fatura_id=f.id
join patrocinadores p on p.id=f.patrocinador_id
where p.empresa='Alfa Cloud' order by fi.descricao;

\echo ''
\echo '=== 6 · Bruno tenta escrever no quarto da Alfa (deve FALHAR) ==='
set role authenticated;
set request.jwt.claims = '{"email":"bruno@beta.test","role":"authenticated"}';
select patro_salvar_quarto(:'res1'::uuid,
  '[{"nome":"Invasor","tipo":"adulto"}]'::jsonb, false, null, false, null);
\echo '-- e tenta cancelar o quarto extra da Alfa (deve FALHAR):'
select patro_cancelar_quarto_extra(
  (select r.id from reservas r where r.patrocinador_id=:'alfa'::uuid and r.origem='extra' limit 1));
reset role;

\echo ''
\echo '=== 7 · fluxo do participante (Carlos) ==='
set role authenticated;
set request.jwt.claims = '{"email":"carlos@cliente.test","role":"authenticated"}';
select part_meu_status('cerrado2027')->>'rooming_liberado' as rooming_liberado,
       part_meu_status('cerrado2027')->>'status_contrato'  as contrato;

\echo '-- previa: acompanhante 800 + crianca 400 + 2 transfers 300 = 1500'
select part_previa_fatura('cerrado2027',
  '[{"nome":"Maria","tipo":"adulto","data_nascimento":"1985-03-02","usa_transfer":true},
    {"nome":"Joao","tipo":"crianca","data_nascimento":"2020-05-10","usa_transfer":false}]'::jsonb,
  true);

\echo '-- salva:'
select part_salvar_rooming('cerrado2027',
  '[{"nome":"Maria","tipo":"adulto","data_nascimento":"1985-03-02","usa_transfer":true},
    {"nome":"Joao","tipo":"crianca","data_nascimento":"2020-05-10","usa_transfer":false}]'::jsonb,
  true, 'BSB');

\echo '-- ocupantes (o titular deve aparecer sem ter sido enviado):'
select nome, tipo, usa_transfer from part_listar_rooming('cerrado2027');
reset role;

\echo '-- fatura do Carlos:'
select fi.descricao, fi.valor_unit from faturas f
join fatura_itens fi on fi.fatura_id=f.id
join participantes pa on pa.id=f.participante_id
join gestores g on g.id=pa.gestor_id
where g.email_norm=norm_doc('carlos@cliente.test') order by fi.descricao;
select 'TOTAL: ' || f.total from faturas f
join participantes pa on pa.id=f.participante_id
join gestores g on g.id=pa.gestor_id
where g.email_norm=norm_doc('carlos@cliente.test');

\echo ''
\echo '=== 8 · anon ==='
set role anon;
set request.jwt.claims = '{"role":"anon"}';
\echo '-- admin_listar_equipe (deve FALHAR por permissao):'
select * from admin_listar_equipe();
\echo '-- patro_meu_painel (deve FALHAR por permissao):'
select * from patro_meu_painel('cerrado2027');
\echo '-- part_autocadastro (deve FUNCIONAR):'
select part_autocadastro('cerrado2027','Novo CIO','novo@cliente.test','Empresa Nova');
reset role;
