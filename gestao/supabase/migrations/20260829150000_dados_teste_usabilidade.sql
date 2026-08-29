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
-- como o PostgREST faz — efeito colateral de cada uma (patrocinador
-- ja pede geracao de quarto) acontece de verdade, sem duplicar a
-- logica na mao.
--
-- TUDO NUM SO BLOCO DO $$...$$: a primeira versao usava uma tabela
-- temporaria pra levar ids de uma troca de papel pra outra
-- (`set role` / `reset role` como statements soltos), e o runner do
-- `db push` ("LegacyDbPushApplyError") nao lidou bem com isso — deu
-- erro de tipo numa linha que nao tinha ambiguidade nenhuma, tanto
-- localmente (supabase_db_gestao-cio-cerrado, testado antes) quanto
-- depois de eu ja ter posto lista de colunas explicita. Um bloco DO
-- so e um unico statement do ponto de vista de qualquer runner —
-- SET ROLE/SET request.jwt.claims entram via EXECUTE (nao sao
-- statement direto de PL/pgSQL), variaveis locais levam o id de um
-- passo pro outro, sem tabela temporaria nenhuma.
--
-- Para remover depois do teste, apague pelo slug do evento e pelos
-- e-mails +admin/+staff/+patrocinador/+cio — CASCADE cuida do resto.
-- =====================================================================

set search_path = gestao, public;

do $$
declare
  v_evento_id uuid;
  v_patro_id uuid;
  v_participante_id uuid;
  v_claims_admin text := '{"email":"gerardocarvalhogp+admin@gmail.com","role":"authenticated"}';
begin
  -- 1. admins — ninguem e admin antes desta linha existir, entao e a
  --    unica insercao que nao passa por funcao.
  insert into admins (email, nome, role, ativo) values
    ('gerardocarvalhogp+admin@gmail.com', 'Teste — Admin (Cowork)', 'admin', true),
    ('gerardocarvalhogp+staff@gmail.com', 'Teste — Staff (Cowork)', 'staff', true)
  on conflict (email_norm) do update set role = excluded.role, ativo = true;

  -- 2. evento isolado
  execute 'set role authenticated';
  execute format('set request.jwt.claims = %L', v_claims_admin);

  perform admin_salvar_evento(
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

  execute 'reset role';
  execute 'reset request.jwt.claims';

  select id into v_evento_id from eventos where slug = 'usabilidade-teste';

  -- 3. cota — vaga de mesa redonda e jantar ligados, pra fila e o
  --    portal terem o que mostrar
  execute 'set role authenticated';
  execute format('set request.jwt.claims = %L', v_claims_admin);

  perform admin_salvar_cota(
    p_evento_slug := 'usabilidade-teste',
    p_nome := 'Ouro',
    p_ordem := 1,
    p_quartos := '{"duplo":1}'::jsonb,
    p_vagas_mesa := 3,
    p_reuniao := false,
    p_jantar := true
  );

  -- 4. patrocinador
  perform admin_salvar_patrocinador(
    p_evento_slug := 'usabilidade-teste',
    p_empresa := 'Empresa Teste Cowork',
    p_cota_nome := 'Ouro',
    p_segmento := 'Tecnologia',
    p_o_que_vende := 'Software de gestão — dado fictício para teste de usabilidade',
    p_status := 'ativo',
    p_cidade := 'Goiânia',
    p_estado := 'GO'
  );

  execute 'reset role';
  execute 'reset request.jwt.claims';

  select id into v_patro_id from patrocinadores
   where empresa = 'Empresa Teste Cowork' and evento_id = v_evento_id;

  execute 'set role authenticated';
  execute format('set request.jwt.claims = %L', v_claims_admin);

  perform admin_salvar_usuario_patro(
    p_patrocinador_id := v_patro_id,
    p_email := 'gerardocarvalhogp+patrocinador@gmail.com',
    p_nome := 'Teste — Patrocinador (Cowork)'
  );

  -- quartos/reservas nao nascem mais sozinhos com o patrocinador — a
  -- versao atual de admin_salvar_patrocinador (a mais recente vence)
  -- tirou a geracao automatica que uma migration anterior tinha
  -- colocado; o botao "Gerar quartos" continua manual na tela.
  perform admin_gerar_quartos_cota(v_patro_id);

  -- 5. CIO / participante — mesmo caminho que uma planilha real do
  --    Sympla usaria, so com uma linha "Aprovado" fabricada
  perform admin_importar_participantes_sympla('usabilidade-teste', jsonb_build_array(
    jsonb_build_object(
      'nome', 'Teste CIO Cowork',
      'email', 'gerardocarvalhogp+cio@gmail.com',
      'empresa', 'Empresa Convidada Teste',
      'cargo', 'CIO',
      'estado_pagamento', 'Aprovado'
    )
  ));

  execute 'reset role';
  execute 'reset request.jwt.claims';

  select pa.id into v_participante_id from participantes pa
    join gestores g on g.id = pa.gestor_id
   where g.email_norm = norm_doc('gerardocarvalhogp+cio@gmail.com')
     and pa.evento_id = v_evento_id;

  execute 'set role authenticated';
  execute format('set request.jwt.claims = %L', v_claims_admin);

  -- aprova formalmente (a importacao ja entra 'aprovado'; isto so
  -- confirma e grava quem aprovou, igual a tela faria)
  perform admin_aprovar_participante(v_participante_id, true);

  -- 6. jantar avulso, pro teste do painel de importacao Sympla e do
  --    check-in — modulo separado, sem evento_id (ver README §6)
  perform jantar_salvar(
    p_patrocinador_nome := 'Empresa Teste Cowork',
    p_data := '2027-09-02',
    p_horario := '20:00',
    p_local := 'Restaurante Teste',
    p_capacidade := 8,
    p_status := 'confirmado',
    p_sympla_url := 'https://www.sympla.com.br/'
  );

  execute 'reset role';
  execute 'reset request.jwt.claims';

  -- 7. contrato assinado — fora do papel de admin porque normalmente
  --    isso vem do webhook/polling do Autentique, nao tem funcao de
  --    tela para "assinar na mao". INSERT direto, mesma forma que
  --    integracao.py grava quando le a assinatura de verdade.
  insert into contratos (participante_id, status, enviado_em, assinado_em)
  values (v_participante_id, 'assinado', now() - interval '2 days', now())
  on conflict (participante_id) do update set
    status = 'assinado', assinado_em = now();
end $$;
