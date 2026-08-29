-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Dados de teste para a rodada de usabilidade com o Cowork.
--
-- NAO E SCHEMA — sao linhas de dado, feitas migration porque e o unico
-- caminho que este projeto tem para escrever no banco hospedado (ver
-- README, "db reset no local, db push no hospedado"). Evento isolado
-- (slug "usabilidade-teste"), nao toca no cerrado2027 de verdade.
--
-- Passa pelas MESMAS funcoes que a tela usa (admin_salvar_evento,
-- admin_salvar_cota, admin_salvar_patrocinador...), trocando de papel
-- como o PostgREST faz — efeito colateral de cada uma (cota unica ja
-- nasce com cota, patrocinador ja nasce com quarto) acontece de
-- verdade, sem duplicar a logica na mao.
--
-- `authenticated` so enxerga tabela por GRANT explicito (a linha
-- "authenticated também perdeu o acesso às tabelas", 20260825090000)
-- — por isso o volta-e-meia RESET ROLE / SET ROLE aqui: toda leitura
-- direta de tabela precisa estar de volta como superusuario, toda
-- chamada de função admin_/jantar_ precisa estar como authenticated
-- com o e-mail certo no claims, senão _exige_admin() recusa.
--
-- Sem \gset (recurso so do psql interativo — nao confiavel dentro do
-- runner do `db push`): os ids que atravessam a troca de papel ficam
-- numa tabela temporaria, com GRANT explicito para authenticated.
--
-- Para remover depois do teste, apague pelo slug do evento e pelos
-- e-mails +admin/+staff/+patrocinador/+cio — CASCADE cuida do resto.
-- =====================================================================

set search_path = gestao, public;

create temporary table _seed_ids (chave text primary key, valor uuid);
grant select, insert on _seed_ids to authenticated;

-- 1. admins — ninguem e admin antes desta linha existir, entao e a
--    unica insercao que nao passa por funcao.
insert into admins (email, nome, role, ativo) values
  ('gerardocarvalhogp+admin@gmail.com', 'Teste — Admin (Cowork)', 'admin', true),
  ('gerardocarvalhogp+staff@gmail.com', 'Teste — Staff (Cowork)', 'staff', true)
on conflict (email_norm) do update set role = excluded.role, ativo = true;

-- 2. evento isolado
set role authenticated;
set request.jwt.claims = '{"email":"gerardocarvalhogp+admin@gmail.com","role":"authenticated"}';
select admin_salvar_evento(
  p_slug := 'usabilidade-teste',
  p_nome := 'CIO Cerrado — Teste de Usabilidade (Cowork)',
  p_local := 'Ambiente de teste',
  p_data_inicio := '2027-09-01',
  p_data_fim := '2027-09-04',
  p_status := 'aberto',
  p_prazo_contrato := '2027-08-20',
  p_prazo_rooming := '2027-08-25',
  p_prazo_cancelamento := '2027-08-15',
  p_cota_unica := false,
  p_escolha_abre_em := now()
);

reset role;
reset request.jwt.claims;
insert into _seed_ids (chave, valor) select 'evento'::text, id from eventos where slug = 'usabilidade-teste';

-- 3. cota — vaga de mesa redonda e jantar ligados, pra fila e o
--    portal terem o que mostrar
set role authenticated;
set request.jwt.claims = '{"email":"gerardocarvalhogp+admin@gmail.com","role":"authenticated"}';
select admin_salvar_cota(
  p_evento_slug := 'usabilidade-teste',
  p_nome := 'Ouro',
  p_ordem := 1,
  p_quartos := '{"duplo":1}'::jsonb,
  p_vagas_mesa := 3,
  p_reuniao := false,
  p_jantar := true
);

-- 4. patrocinador — quartos da cota nascem automaticamente aqui
--    (20260826130000)
select admin_salvar_patrocinador(
  p_evento_slug := 'usabilidade-teste',
  p_empresa := 'Empresa Teste Cowork',
  p_cota_nome := 'Ouro',
  p_segmento := 'Tecnologia',
  p_o_que_vende := 'Software de gestão — dado fictício para teste de usabilidade',
  p_status := 'ativo',
  p_cidade := 'Goiânia',
  p_estado := 'GO'
);

reset role;
reset request.jwt.claims;
insert into _seed_ids (chave, valor)
  select 'patrocinador'::text, id from patrocinadores
   where empresa = 'Empresa Teste Cowork'
     and evento_id = (select valor from _seed_ids where chave = 'evento');

set role authenticated;
set request.jwt.claims = '{"email":"gerardocarvalhogp+admin@gmail.com","role":"authenticated"}';
select admin_salvar_usuario_patro(
  p_patrocinador_id := (select valor from _seed_ids where chave = 'patrocinador'),
  p_email := 'gerardocarvalhogp+patrocinador@gmail.com',
  p_nome := 'Teste — Patrocinador (Cowork)'
);

-- quartos/reservas nao nascem mais sozinhos com o patrocinador — a
-- versao atual de admin_salvar_patrocinador (a mais recente vence)
-- tirou a geracao automatica que a migration 20260826130000 tinha
-- colocado; o botao "Gerar quartos" continua manual na tela. Chamando
-- aqui pra o portal de teste ja abrir com quarto disponivel.
select admin_gerar_quartos_cota(
  (select valor from _seed_ids where chave = 'patrocinador'));

-- 5. CIO / participante — mesmo caminho que uma planilha real do
--    Sympla usaria, so com uma linha "Aprovado" fabricada
select admin_importar_participantes_sympla('usabilidade-teste', jsonb_build_array(
  jsonb_build_object(
    'nome', 'Teste CIO Cowork',
    'email', 'gerardocarvalhogp+cio@gmail.com',
    'empresa', 'Empresa Convidada Teste',
    'cargo', 'CIO',
    'estado_pagamento', 'Aprovado'
  )
));

reset role;
reset request.jwt.claims;
insert into _seed_ids (chave, valor)
  select 'participante'::text, pa.id from participantes pa
    join gestores g on g.id = pa.gestor_id
   where g.email_norm = norm_doc('gerardocarvalhogp+cio@gmail.com')
     and pa.evento_id = (select valor from _seed_ids where chave = 'evento');

-- aprova formalmente (a importacao ja entra 'aprovado'; isto so
-- confirma e grava quem aprovou, igual a tela faria)
set role authenticated;
set request.jwt.claims = '{"email":"gerardocarvalhogp+admin@gmail.com","role":"authenticated"}';
select admin_aprovar_participante(
  (select valor from _seed_ids where chave = 'participante'), true);

-- 6. jantar avulso, pro teste do painel de importacao Sympla e do
--    check-in — modulo separado, sem evento_id (ver README §6)
select jantar_salvar(
  p_patrocinador_nome := 'Empresa Teste Cowork',
  p_data := '2027-09-02',
  p_horario := '20:00',
  p_local := 'Restaurante Teste',
  p_capacidade := 8,
  p_status := 'confirmado',
  p_sympla_url := 'https://www.sympla.com.br/'
);

reset role;
reset request.jwt.claims;

-- 7. contrato assinado — fora do papel de admin porque normalmente
--    isso vem do webhook/polling do Autentique, nao tem funcao de
--    tela para "assinar na mao". INSERT direto, mesma forma que
--    integracao.py grava quando le a assinatura de verdade.
insert into contratos (participante_id, status, enviado_em, assinado_em)
select valor, 'assinado', now() - interval '2 days', now()
  from _seed_ids where chave = 'participante'
on conflict (participante_id) do update set
  status = 'assinado', assinado_em = now();

drop table _seed_ids;
