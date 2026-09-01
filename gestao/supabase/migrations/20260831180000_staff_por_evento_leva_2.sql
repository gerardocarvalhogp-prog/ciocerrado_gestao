-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Staff por evento, leva 2: as funcoes que recebem id de recurso em vez
-- do slug do evento direto.
--
-- A leva anterior (20260831160000) cobriu as 22 funcoes que recebem
-- p_evento_slug. Ficaram de fora as que recebem p_sessao_id, p_reserva_id,
-- p_brinde_id, p_atividade_id, p_checkin_id etc — staff que soubesse um
-- id de outro evento ainda acessava, gap registrado explicitamente
-- naquela migration para nao ser esquecido.
--
-- MESMO GUARD, RESOLVIDO POR CAMINHO DIFERENTE
--
-- `_exige_staff_do_evento_slug` virou fina camada sobre um novo
-- `_exige_staff_do_evento(uuid)` — a mesma logica de admin-bypass e
-- checagem de associacao, so que recebendo o id do evento em vez do
-- slug. Cinco helpers novos resolvem esse id a partir do recurso que
-- cada funcao recebe (sessao, reserva, brinde, atividade, checkin) e
-- chamam o mesmo core — nao ha checagem duplicada, so caminho
-- diferente ate o mesmo lugar.
--
-- 13 FUNCOES TROCADAS NESTA LEVA
--
-- admin_adicionar_convidado_sessao, admin_alocar_quarto,
-- admin_convidado_avulso, admin_convidados_sessao, admin_mailing_sessao,
-- admin_marcar_brinde, admin_match_jantar (opera sobre sessao, nao
-- jantar — apesar do nome), admin_preparar_cobranca,
-- admin_remover_convidado_sessao, atividade_checkin_listar,
-- atividade_checkin_registrar, checkin_desfazer, notificacao_marcar.
--
-- FICA DE FORA, E PRECISA FICAR: OS JANTARES
--
-- `jantares` NAO TEM coluna evento_id — conferido no catalogo antes de
-- escrever esta migration. E um jantar avulso, por desenho: nada na
-- tabela liga um jantar a uma edicao especifica do evento. Escopar as
-- 11 funcoes jantar_* por evento exigiria adicionar a coluna e decidir
-- como preencher jantar ja cadastrado (por data? por patrocinador?
-- nenhuma das duas e confiavel) — mudanca de schema, nao troca de
-- guard. Decisao para quando alguem confirmar que jantar DEVE ser
-- escopado por evento, e como migrar o que ja existe.
--
-- `notificacoes_pendentes` tambem fica de fora: e a fila inteira, de
-- proposito (o botao "Enviar toda a fila" processa tudo de uma vez,
-- de qualquer evento) — so e alcancada pela aba Equipe, que ja e
-- admin-only na tela. Escopar isso mudaria o que o botao faz, nao so
-- fecharia um buraco.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. O CORE PASSA A RECEBER O ID DO EVENTO; O SLUG VIRA CAMADA FINA
-- ---------------------------------------------------------------------
create or replace function _exige_staff_do_evento(p_evento_id uuid)
returns void language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  if is_admin() then return; end if;

  -- recurso inexistente: deixa o corpo da funcao chamadora acusar isso
  -- do jeito que ja acusa hoje — aqui so decide sobre acesso
  if p_evento_id is null then return; end if;

  if not exists (
    select 1 from admins a
    join admin_eventos ae on ae.admin_id = a.id
    where a.email_norm = norm_doc(auth.jwt() ->> 'email')
      and a.ativo and ae.evento_id = p_evento_id
  ) then
    raise exception 'Sua conta nao esta associada a este evento' using errcode = '42501';
  end if;
end;
$$;

create or replace function _exige_staff_do_evento_slug(p_evento_slug text)
returns void language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid;
begin
  select id into v_evento from eventos where slug = p_evento_slug;
  perform _exige_staff_do_evento(v_evento);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. UM HELPER POR TIPO DE RECURSO, CADA UM RESOLVENDO O EVENTO A SEU
--    JEITO E CHAMANDO O MESMO CORE
-- ---------------------------------------------------------------------
create or replace function _exige_staff_da_sessao(p_sessao_id uuid)
returns void language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid;
begin
  select evento_id into v_evento from sessoes where id = p_sessao_id;
  perform _exige_staff_do_evento(v_evento);
end;
$$;

create or replace function _exige_staff_da_reserva(p_reserva_id uuid)
returns void language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid;
begin
  select evento_id into v_evento from reservas where id = p_reserva_id;
  perform _exige_staff_do_evento(v_evento);
end;
$$;

create or replace function _exige_staff_do_brinde(p_brinde_id uuid)
returns void language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid;
begin
  select p.evento_id into v_evento
  from brindes b join patrocinadores p on p.id = b.patrocinador_id
  where b.id = p_brinde_id;
  perform _exige_staff_do_evento(v_evento);
end;
$$;

create or replace function _exige_staff_da_atividade(p_atividade_id uuid)
returns void language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid;
begin
  select evento_id into v_evento from atividades where id = p_atividade_id;
  perform _exige_staff_do_evento(v_evento);
end;
$$;

create or replace function _exige_staff_do_checkin(p_checkin_id uuid)
returns void language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid;
begin
  select evento_id into v_evento from checkins where id = p_checkin_id;
  perform _exige_staff_do_evento(v_evento);
end;
$$;

revoke execute on function _exige_staff_do_evento(uuid) from public, anon;
revoke execute on function _exige_staff_da_sessao(uuid) from public, anon;
revoke execute on function _exige_staff_da_reserva(uuid) from public, anon;
revoke execute on function _exige_staff_do_brinde(uuid) from public, anon;
revoke execute on function _exige_staff_da_atividade(uuid) from public, anon;
revoke execute on function _exige_staff_do_checkin(uuid) from public, anon;
grant execute on function _exige_staff_do_evento(uuid) to authenticated, service_role;
grant execute on function _exige_staff_da_sessao(uuid) to authenticated, service_role;
grant execute on function _exige_staff_da_reserva(uuid) to authenticated, service_role;
grant execute on function _exige_staff_do_brinde(uuid) to authenticated, service_role;
grant execute on function _exige_staff_da_atividade(uuid) to authenticated, service_role;
grant execute on function _exige_staff_do_checkin(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. AS 13 FUNCOES: MESMO CORPO, SO O GUARD TROCA
-- ---------------------------------------------------------------------

create or replace function gestao.admin_adicionar_convidado_sessao(p_sessao_id uuid, p_participante_id uuid, p_aderencia numeric DEFAULT NULL::numeric)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_da_sessao(p_sessao_id);

  insert into sessao_convidados (sessao_id, participante_id, origem, aderencia)
  values (p_sessao_id, p_participante_id, 'admin', p_aderencia)
  on conflict do nothing;

  return jsonb_build_object('ok', true);
end;
$function$;

create or replace function gestao.admin_alocar_quarto(p_reserva_id uuid, p_quarto_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare
  v_anterior uuid; v_ocupado uuid; v_cap int; v_qtd int; v_tipo text;
begin
  perform _exige_staff_da_reserva(p_reserva_id);

  select quarto_id into v_anterior from reservas where id = p_reserva_id;
  if not found then
    raise exception 'Reserva nao encontrada' using errcode = 'P0002';
  end if;

  if p_quarto_id is null then
    update reservas set quarto_id = null where id = p_reserva_id;
    update quartos set status = 'disponivel' where id = v_anterior;
    return jsonb_build_object('ok', true, 'liberado', true);
  end if;

  select q.capacidade, q.tipo into v_cap, v_tipo
  from quartos q where q.id = p_quarto_id for update;

  select r.id into v_ocupado from reservas r
   where r.quarto_id = p_quarto_id and r.status <> 'cancelado'
     and r.id <> p_reserva_id
   limit 1;

  if v_ocupado is not null then
    return jsonb_build_object('ok', false, 'motivo', 'quarto_ocupado');
  end if;

  select count(*) into v_qtd from ocupantes where reserva_id = p_reserva_id;

  if v_qtd > v_cap then
    return jsonb_build_object('ok', false, 'motivo', 'capacidade',
      'ocupantes', v_qtd, 'capacidade', v_cap);
  end if;

  update reservas set quarto_id = p_quarto_id where id = p_reserva_id;
  update quartos set status = 'reservado' where id = p_quarto_id;

  if v_anterior is not null and v_anterior <> p_quarto_id then
    update quartos set status = 'disponivel' where id = v_anterior;
  end if;

  return jsonb_build_object('ok', true);
end;
$function$;

create or replace function gestao.admin_convidado_avulso(p_sessao_id uuid, p_nome text, p_empresa text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_telefone text DEFAULT NULL::text, p_cargo text DEFAULT NULL::text, p_rotulo text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare
  v_evento uuid; v_gestor uuid; v_part uuid;
  v_vagas int; v_ocupadas int; v_reaproveitado boolean := false;
begin
  perform _exige_staff_da_sessao(p_sessao_id);

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome' using errcode='22023';
  end if;

  select s.evento_id, s.vagas into v_evento, v_vagas
  from sessoes s where s.id = p_sessao_id;

  if v_evento is null then
    raise exception 'Sessao nao encontrada' using errcode='P0002';
  end if;

  select count(*) into v_ocupadas from sessao_convidados
   where sessao_id = p_sessao_id and status = 'confirmado';

  if v_ocupadas >= v_vagas then
    raise exception 'A sessao ja tem % de % vaga(s) ocupada(s)', v_ocupadas, v_vagas
      using errcode='22023';
  end if;

  if coalesce(trim(p_email),'') <> '' then
    select g.id into v_gestor from gestores g
     where g.email_norm = norm_doc(p_email);
    v_reaproveitado := v_gestor is not null;
  end if;

  if v_gestor is null then
    insert into gestores (nome, email, empresa, cargo, telefone, perfil, origem)
    values (trim(p_nome),
            coalesce(nullif(lower(trim(p_email)),''),
                     'avulso.' || replace(gen_random_uuid()::text,'-','')
                     || '@interno.ciocerrado.com.br'),
            p_empresa, p_cargo, p_telefone,
            coalesce(nullif(trim(p_rotulo),''), 'CONVIDADO'), 'manual')
    returning id into v_gestor;
  end if;

  select pa.id into v_part from participantes pa
   where pa.evento_id = v_evento and pa.gestor_id = v_gestor;

  if v_part is null then
    insert into participantes (evento_id, gestor_id, status, origem, aprovado_em,
                               aprovado_por)
    values (v_evento, v_gestor, 'aprovado', 'manual', now(),
            auth.jwt() ->> 'email')
    returning id into v_part;
  else
    update participantes set status = 'aprovado'
     where id = v_part and status <> 'aprovado';
  end if;

  insert into sessao_convidados (sessao_id, participante_id, origem, rotulo)
  values (p_sessao_id, v_part, 'admin', nullif(trim(p_rotulo),''))
  on conflict do nothing;

  if v_ocupadas + 1 >= v_vagas then
    update sessoes set escolha_encerrada_em = now() where id = p_sessao_id;
  end if;

  return jsonb_build_object('ok', true, 'participante_id', v_part,
                            'gestor_reaproveitado', v_reaproveitado);
end;
$function$;

create or replace function gestao.admin_convidados_sessao(p_sessao_id uuid)
 returns table(participante_id uuid, nome text, empresa text, cargo text, email text, origem text, rotulo text, aderencia numeric)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_da_sessao(p_sessao_id);
  return query
    select sc.participante_id, g.nome, g.empresa, g.cargo, g.email,
           sc.origem, sc.rotulo, sc.aderencia
    from sessao_convidados sc
    join participantes pa on pa.id = sc.participante_id
    join gestores g on g.id = pa.gestor_id
    where sc.sessao_id = p_sessao_id and sc.status = 'confirmado'
    order by g.empresa, g.nome;
end;
$function$;

create or replace function gestao.admin_mailing_sessao(p_sessao_id uuid)
 returns table(nome text, cargo text, empresa text, email text, telefone text, rotulo text)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_da_sessao(p_sessao_id);
  return query
    select g.nome, g.cargo, g.empresa,
           case when g.email like '%@interno.ciocerrado.com.br' then null
                else g.email end,
           g.telefone,
           coalesce(sc.rotulo, g.perfil)
    from sessao_convidados sc
    join participantes pa on pa.id = sc.participante_id
    join gestores g on g.id = pa.gestor_id
    where sc.sessao_id = p_sessao_id and sc.status = 'confirmado'
    order by g.empresa, g.nome;
end;
$function$;

create or replace function gestao.admin_marcar_brinde(p_brinde_id uuid, p_status text, p_observacao text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare v_ant text; v_quem text;
begin
  perform _exige_staff_do_brinde(p_brinde_id);

  select status into v_ant from brindes where id = p_brinde_id;
  if v_ant is null then
    raise exception 'Brinde nao encontrado' using errcode = 'P0002';
  end if;
  if p_status not in ('prometido','enviado','recebido','entregue','cancelado') then
    raise exception 'Status invalido: %', p_status using errcode = '22023';
  end if;

  v_quem := auth.jwt() ->> 'email';

  update brindes set
    status = p_status,
    enviado_em = case
      when p_status in ('enviado','recebido','entregue') then coalesce(enviado_em, now())
      else null end,
    recebido_em = case
      when p_status in ('recebido','entregue') then coalesce(recebido_em, now())
      else null end,
    recebido_por = case
      when p_status in ('recebido','entregue') then coalesce(recebido_por, v_quem)
      else null end,
    entregue_em = case
      when p_status = 'entregue' then coalesce(entregue_em, now())
      else null end,
    entregue_por = case
      when p_status = 'entregue' then coalesce(entregue_por, v_quem)
      else null end,
    observacao = coalesce(p_observacao, observacao),
    updated_at = now()
  where id = p_brinde_id;

  return jsonb_build_object('ok', true, 'de', v_ant, 'para', p_status);
end;
$function$;

create or replace function gestao.admin_match_jantar(p_sessao_id uuid, p_limite integer DEFAULT 20)
 returns table(participante_id uuid, nome text, empresa text, segmento text, faturamento text, aderencia numeric)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
declare v_evento uuid; v_patro_seg text; v_vende text; v_tipo text;
begin
  perform _exige_staff_da_sessao(p_sessao_id);

  select s.evento_id, s.tipo, p.segmento, p.o_que_vende
    into v_evento, v_tipo, v_patro_seg, v_vende
  from sessoes s join patrocinadores p on p.id = s.patrocinador_id
  where s.id = p_sessao_id;

  return query
    select pa.id, g.nome, g.empresa, g.segmento, pp.faturamento,
      round(
        (case when v_patro_seg is not null
               and lower(coalesce(g.segmento,'')) = lower(v_patro_seg)
              then 50 else 0 end)
        + (case when v_vende is not null
                 and coalesce(pp.respostas::text,'') ilike '%' || v_vende || '%'
                then 30 else 0 end)
        + (case when pp.faturamento ilike '%bilh%' then 20
                when pp.faturamento ilike '%milh%' then 10
                else 0 end)
      , 2)::numeric as aderencia
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    left join participante_perfil pp on pp.participante_id = pa.id
    where pa.evento_id = v_evento
      and pa.status = 'aprovado'
      and not exists (
        select 1 from sessao_convidados sc
        join sessoes s3 on s3.id = sc.sessao_id
        where sc.participante_id = pa.id and sc.status = 'confirmado'
          and s3.evento_id = v_evento and s3.tipo = v_tipo)
    order by aderencia desc, g.empresa
    limit p_limite;
end;
$function$;

create or replace function gestao.admin_preparar_cobranca(p_sujeito_id uuid, p_etapa_chave text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
declare
  v_row record;
  v_destinatarios text[];
  v_assunto text;
  v_corpo text;
  v_ultimo timestamptz;
begin
  perform _exige_staff();

  select * into v_row from v_pendencias
   where sujeito_id = p_sujeito_id and etapa_chave = p_etapa_chave
   limit 1;
  if v_row is null then
    raise exception 'Pendência não encontrada' using errcode = 'P0002';
  end if;

  perform _exige_staff_do_evento(v_row.evento_id);

  if v_row.status = 'concluida' then
    raise exception 'Essa etapa já foi concluída — não há pendência para cobrar'
      using errcode = '55000';
  end if;

  if v_row.publico = 'participante' then
    v_destinatarios := array[v_row.destinatario_email];
  else
    select array_agg(up.email) into v_destinatarios
    from usuarios_patrocinador up
    where up.patrocinador_id = v_row.sujeito_id and up.ativo;
  end if;

  select max(n.created_at) into v_ultimo
  from notificacoes n
  where n.tipo = 'cobranca_' || p_etapa_chave
    and n.destinatario = any(coalesce(v_destinatarios, array[]::text[]))
    and n.created_at > now() - interval '3 days';

  v_assunto := 'CIO Cerrado — ' || v_row.etapa_rotulo;
  v_corpo := case v_row.etapa_chave
    when 'contrato_assinado' then
      'Olá! Notamos que o contrato ainda não foi assinado. Pode verificar quando tiver um momento?'
    when 'hospedagem_preenchida' then
      'Olá! Os dados de hospedagem ainda não foram preenchidos. O prazo está próximo — pode completar quando puder?'
    when 'fatura_paga' then
      'Olá! Há uma fatura em aberto. Qualquer dúvida sobre o valor, é só responder este e-mail.'
    when 'presenca_confirmada' then
      'Olá! Ainda não temos sua confirmação de presença. Pode confirmar quando puder?'
    when 'contrato_patrocinio_assinado' then
      'Olá! O contrato de patrocínio ainda não foi assinado. Pode verificar quando tiver um momento?'
    when 'indicacao_cio_feita' then
      'Olá! Ainda não recebemos indicações de CIOs da sua empresa para este evento.'
    when 'quartos_preenchidos' then
      'Olá! Os ocupantes dos quartos da cota ainda não foram todos preenchidos.'
    when 'convidados_mesa_escolhidos' then
      'Olá! Os convidados de mesa redonda ainda não foram escolhidos.'
    when 'convidados_jantar_escolhidos' then
      'Olá! Os convidados de jantar ainda não foram escolhidos.'
    when 'brindes_definidos' then
      'Olá! Ainda não recebemos a definição de brindes da sua empresa.'
    else 'Olá! Notamos uma pendência: ' || v_row.etapa_rotulo || '.'
  end;

  return jsonb_build_object(
    'destinatarios', to_jsonb(coalesce(v_destinatarios, array[]::text[])),
    'assunto', v_assunto,
    'corpo', v_corpo,
    'dias_em_aberto', v_row.dias_em_aberto,
    'ja_enviado_recentemente', v_ultimo is not null,
    'ultimo_envio', v_ultimo
  );
end;
$function$;

create or replace function gestao.admin_remover_convidado_sessao(p_sessao_id uuid, p_participante_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_da_sessao(p_sessao_id);

  update sessao_convidados set status = 'removido'
   where sessao_id = p_sessao_id and participante_id = p_participante_id;

  update sessoes set escolha_encerrada_em = null where id = p_sessao_id;

  return jsonb_build_object('ok', true);
end;
$function$;

create or replace function gestao.atividade_checkin_listar(p_atividade_id uuid, p_termo text DEFAULT NULL::text, p_so_pendentes boolean DEFAULT false, p_limite integer DEFAULT 300)
 returns table(pessoa_key text, nome text, empresa text, categoria text, checkin_id uuid, registrado_em timestamp with time zone)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
declare v_evento uuid; v_termo text;
begin
  perform _exige_staff_da_atividade(p_atividade_id);
  select evento_id into v_evento from atividades where id = p_atividade_id;
  if v_evento is null then
    raise exception 'Atividade nao encontrada' using errcode = 'P0002';
  end if;
  v_termo := nullif(trim(coalesce(p_termo,'')), '');

  return query
    select v.pessoa_key, v.nome, v.empresa, v.categoria, c.id, c.registrado_em
    from v_esperados v
    left join checkins c on c.pessoa_key = v.pessoa_key
                         and c.atividade_id = p_atividade_id
                         and c.desfeito_em is null
    where v.evento_id = v_evento
      and (v_termo is null
           or v.nome ilike '%'||v_termo||'%'
           or coalesce(v.empresa,'') ilike '%'||v_termo||'%')
      and (not p_so_pendentes or c.id is null)
    order by (c.id is not null), v.nome
    limit p_limite;
end;
$function$;

create or replace function gestao.atividade_checkin_registrar(p_atividade_id uuid, p_pessoa_key text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare
  v_evento uuid; v_nome text; v_email text; v_patro uuid; v_ocupante uuid;
  v_ja timestamptz; v_id uuid;
begin
  perform _exige_staff_da_atividade(p_atividade_id);

  select evento_id into v_evento from atividades where id = p_atividade_id;
  if v_evento is null then
    raise exception 'Atividade nao encontrada' using errcode = 'P0002';
  end if;

  select v.nome, v.email, v.patrocinador_id
    into v_nome, v_email, v_patro
  from v_esperados v
  where v.pessoa_key = p_pessoa_key and v.evento_id = v_evento;

  if v_nome is null then
    raise exception 'Pessoa nao encontrada neste evento' using errcode = 'P0002';
  end if;

  if p_pessoa_key like 'ocupante:%' then
    v_ocupante := substring(p_pessoa_key from 10)::uuid;
  end if;

  select c.registrado_em into v_ja from checkins c
   where c.pessoa_key = p_pessoa_key and c.atividade_id = p_atividade_id
     and c.desfeito_em is null
   limit 1;

  if v_ja is not null then
    return jsonb_build_object('ok', true, 'ja_estava', true,
                              'nome', v_nome, 'registrado_em', v_ja);
  end if;

  insert into checkins (evento_id, patrocinador_id, ocupante_id, pessoa_key,
                        nome, email, atividade_id, registrado_por)
  values (v_evento, v_patro, v_ocupante, p_pessoa_key, v_nome, v_email,
          p_atividade_id, auth.jwt() ->> 'email')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'ja_estava', false, 'id', v_id, 'nome', v_nome);
end;
$function$;

create or replace function gestao.checkin_desfazer(p_checkin_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare v_n int;
begin
  perform _exige_staff_do_checkin(p_checkin_id);

  update checkins
     set desfeito_em = now(),
         desfeito_por = auth.jwt() ->> 'email'
   where id = p_checkin_id and desfeito_em is null;

  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'Check-in nao encontrado ou ja desfeito.' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true);
end;
$function$;

create or replace function gestao.notificacao_marcar(p_id uuid, p_ok boolean, p_erro text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare v_evento uuid;
begin
  perform _exige_staff();

  select evento_id into v_evento from notificacoes where id = p_id;
  if v_evento is not null then
    perform _exige_staff_do_evento(v_evento);
  end if;

  update notificacoes set
    status     = case when p_ok then 'enviada' else 'erro' end,
    enviada_em = case when p_ok then now() else enviada_em end,
    erro       = case when p_ok then null else left(coalesce(p_erro,'falha'), 500) end,
    tentativas = tentativas + 1
  where id = p_id;
  if not found then
    raise exception 'Notificacao nao encontrada' using errcode='P0002';
  end if;
  return jsonb_build_object('ok', true);
end;
$function$;
