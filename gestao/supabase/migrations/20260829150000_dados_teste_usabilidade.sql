-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Dados de teste para a rodada de usabilidade com o Cowork.
--
-- NAO E SCHEMA — sao linhas de dado, feitas migration porque e o unico
-- caminho que este projeto tem para escrever no banco hospedado (ver
-- README, "db reset no local, db push no hospedado"). Evento isolado
-- (slug "usabilidade-teste"), nao toca no cerrado2027 de verdade.
--
-- INSERT DIRETO, sem passar pelas funcoes admin_/jantar_ e sem
-- alternar papel (`set role authenticated`). Duas tentativas
-- anteriores usaram esse caminho (mesmo padrao de
-- supabase/tests/*.sql) e funcionaram perfeitamente local — o runner
-- do `db push` no hospedado ("LegacyDbPushApplyError") nao se
-- comportou igual: primeiro um erro de tipo numa linha sem
-- ambiguidade, depois "permission denied" logo apos um RESET ROLE que
-- deveria ter devolvido acesso total. Prova de que SET ROLE/RESET
-- ROLE dentro desse runner especifico nao e confiavel — troquei pelo
-- caminho sem essa dependencia: leitura do corpo de cada funcao
-- (admin_salvar_evento, admin_salvar_cota, admin_salvar_patrocinador,
-- admin_gerar_quartos_cota, admin_salvar_usuario_patro, admin_importar_
-- participantes_sympla, admin_aprovar_participante, jantar_salvar) e
-- reproducao exata do INSERT que cada uma faz, correndo como
-- superusuario o tempo todo.
--
-- Para remover depois do teste, apague pelo slug do evento e pelos
-- e-mails +admin/+staff/+patrocinador/+cio — CASCADE cuida do resto.
-- =====================================================================

set search_path = gestao, public;

do $$
declare
  v_evento_id uuid;
  v_cota_id uuid;
  v_patro_id uuid;
  v_gestor_id uuid;
  v_participante_id uuid;
begin
  -- 1. admins
  insert into admins (email, nome, role, ativo) values
    ('gerardocarvalhogp+admin@gmail.com', 'Teste — Admin (Cowork)', 'admin', true),
    ('gerardocarvalhogp+staff@gmail.com', 'Teste — Staff (Cowork)', 'staff', true)
  on conflict (email_norm) do update set role = excluded.role, ativo = true;

  -- 2. evento isolado (mesmo shape de admin_salvar_evento)
  insert into eventos (slug, nome, local, data_inicio, data_fim, status,
                       prazo_contrato, prazo_rooming, prazo_cancelamento,
                       cota_unica, escolha_abre_em)
  values ('usabilidade-teste', 'CIO Cerrado — Teste de Usabilidade (Cowork)',
          'Ambiente de teste', '2027-09-01', '2027-09-04', 'aberto',
          '2027-08-20', '2027-08-25', '2027-08-15', false, now())
  on conflict (slug) do update set
    nome = excluded.nome, status = excluded.status,
    data_inicio = excluded.data_inicio, data_fim = excluded.data_fim,
    prazo_contrato = excluded.prazo_contrato, prazo_rooming = excluded.prazo_rooming,
    prazo_cancelamento = excluded.prazo_cancelamento, escolha_abre_em = excluded.escolha_abre_em
  returning id into v_evento_id;

  -- 3. cota (mesmo shape de admin_salvar_cota, com p_quartos:={"duplo":1})
  insert into cotas (evento_id, nome, ordem_prioridade, vagas_mesa_redonda,
                     tem_reuniao_exclusiva, tem_jantar, quartos_incluidos,
                     tipo_quarto_padrao)
  values (v_evento_id, 'Ouro', 1, 3, false, true, 1, 'duplo')
  on conflict (evento_id, nome) do update set
    vagas_mesa_redonda = excluded.vagas_mesa_redonda, tem_jantar = excluded.tem_jantar
  returning id into v_cota_id;

  delete from cota_quartos where cota_id = v_cota_id;
  insert into cota_quartos (cota_id, tipo, quantidade) values (v_cota_id, 'duplo', 1);

  -- 4. patrocinador (mesmo shape de admin_salvar_patrocinador)
  insert into patrocinadores (evento_id, cota_id, empresa, segmento, o_que_vende,
                              status, cidade, estado)
  values (v_evento_id, v_cota_id, 'Empresa Teste Cowork', 'Tecnologia',
          'Software de gestão — dado fictício para teste de usabilidade',
          'ativo', 'Goiânia', 'GO')
  on conflict (evento_id, lower(empresa)) do update set
    cota_id = excluded.cota_id, status = excluded.status
  returning id into v_patro_id;

  -- 5. usuario do patrocinador (mesmo shape de admin_salvar_usuario_patro)
  insert into usuarios_patrocinador (patrocinador_id, email, nome, ativo)
  values (v_patro_id, 'gerardocarvalhogp+patrocinador@gmail.com',
          'Teste — Patrocinador (Cowork)', true)
  on conflict (patrocinador_id, email_norm) do update set ativo = true;

  -- 6. quarto da cota (mesmo shape de admin_gerar_quartos_cota — cria
  --    reserva em rascunho, sem quarto fisico vinculado ainda)
  if not exists (select 1 from reservas where patrocinador_id = v_patro_id
                  and origem = 'cota' and status <> 'cancelado') then
    insert into reservas (evento_id, patrocinador_id, rotulo, tipo, origem, status)
    values (v_evento_id, v_patro_id, 'Quarto 1', 'duplo', 'cota', 'rascunho');
  end if;

  -- 7. CIO / participante (mesmo shape de admin_importar_participantes_sympla,
  --    aprovado direto)
  insert into gestores (nome, email, empresa, cargo, origem)
  values ('Teste CIO Cowork', 'gerardocarvalhogp+cio@gmail.com',
          'Empresa Convidada Teste', 'CIO', 'importacao')
  on conflict (email_norm) do update set nome = excluded.nome
  returning id into v_gestor_id;

  insert into participantes (evento_id, gestor_id, status, origem,
                             aprovado_em, aprovado_por)
  values (v_evento_id, v_gestor_id, 'aprovado', 'manual', now(), 'seed-teste-usabilidade')
  on conflict (evento_id, gestor_id) do update set
    status = 'aprovado', aprovado_em = excluded.aprovado_em
  returning id into v_participante_id;

  -- 8. contrato assinado (rooming so abre com inscricao aprovada E
  --    contrato assinado — normalmente vem do Autentique, sem funcao
  --    de tela pra "assinar na mao")
  insert into contratos (participante_id, status, enviado_em, assinado_em)
  values (v_participante_id, 'assinado', now() - interval '2 days', now())
  on conflict (participante_id) do update set
    status = 'assinado', assinado_em = now();

  -- 9. jantar avulso (mesmo shape de jantar_salvar — modulo separado,
  --    sem evento_id, ver README §6). Sem unique key pra conflitar —
  --    guarda por existencia, senao um re-run duplica.
  if not exists (select 1 from jantares
                  where patrocinador_nome = 'Empresa Teste Cowork'
                    and data = '2027-09-02') then
    insert into jantares (patrocinador_nome, data, horario, local, capacidade,
                          status, sympla_url, criado_por)
    values ('Empresa Teste Cowork', '2027-09-02', '20:00', 'Restaurante Teste',
            8, 'confirmado', 'https://www.sympla.com.br/', 'seed-teste-usabilidade');
  end if;
end $$;
