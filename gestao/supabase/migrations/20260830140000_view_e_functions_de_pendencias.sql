-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Modulo de acompanhamento, presenca e cobranca — parte 4/4
--
-- v_pendencias_fatos: uma linha por (pessoa/empresa x etapa) que
-- REALMENTE se aplica a ela — etapa que nao se aplica simplesmente
-- nao gera linha (ex.: fatura so aparece pra quem tem fatura de
-- verdade). Cada bloco do UNION decide isso na origem, pra nao
-- precisar de um valor "nao_se_aplica" espalhado por toda consulta.
--
-- v_pendencias: junta com prazos_evento e calcula nivel. Etapa sem
-- prazo configurado (ou com ativo=false) nesse evento simplesmente
-- some — e assim que uma etapa fica desligada por evento.
--
-- fatura_paga e tratada a parte: o prazo conta do vencimento da
-- fatura, nao da abertura da etapa.
-- =====================================================================

set search_path = gestao, public;

create or replace view v_pendencias_fatos as
  -- 1. inscricao aprovada
  select pa.evento_id, 'participante'::text as publico, pa.id as sujeito_id,
         g.nome as sujeito_nome, g.empresa as sujeito_empresa,
         'inscricao_aprovada'::text as etapa_chave,
         pa.created_at as aberta_em, pa.aprovado_em as concluida_em,
         null::date as vencimento, g.email as destinatario_email
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  where pa.status not in ('recusado','cancelado')

  union all
  -- 2. contrato assinado
  select pa.evento_id, 'participante', pa.id, g.nome, g.empresa,
         'contrato_assinado', pa.aprovado_em, c.assinado_em,
         null, g.email
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  left join contratos c on c.participante_id = pa.id
  where pa.status = 'aprovado'
    and (c.status is null or c.status not in ('recusado','cancelado'))

  union all
  -- 3. hospedagem preenchida (rooming + acompanhantes + transfer: um
  -- so save na tela, uma so etapa aqui — ver proposta, decisao D1)
  select pa.evento_id, 'participante', pa.id, g.nome, g.empresa,
         'hospedagem_preenchida', c.assinado_em, r.completo_em,
         null, g.email
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  join contratos c on c.participante_id = pa.id and c.status = 'assinado'
  left join reservas r on r.participante_id = pa.id and r.status <> 'cancelado'

  union all
  -- 4. fatura adicional paga (prazo especial: conta do vencimento)
  select f.evento_id, 'participante', f.participante_id, g.nome, g.empresa,
         'fatura_paga', f.created_at, f.paga_em,
         f.vencimento, g.email
  from faturas f
  join participantes pa on pa.id = f.participante_id
  join gestores g on g.id = pa.gestor_id
  where f.status <> 'cancelada' and f.total > 0

  union all
  -- 5. presenca confirmada em sessao (mesa redonda ou jantar) — so
  -- quem foi de fato convidado
  select s.evento_id, 'participante', sc.participante_id, g.nome, g.empresa,
         'presenca_confirmada', sc.created_at, sc.resposta_em,
         null, g.email
  from sessao_convidados sc
  join sessoes s on s.id = sc.sessao_id
  join participantes pa on pa.id = sc.participante_id
  join gestores g on g.id = pa.gestor_id
  where sc.status = 'confirmado'

  union all
  -- 6. contrato de patrocinio assinado
  select p.evento_id, 'patrocinador', p.id, null, p.empresa,
         'contrato_patrocinio_assinado', p.created_at, c.assinado_em,
         null, null
  from patrocinadores p
  left join contratos c on c.patrocinador_id = p.id
  where p.status = 'ativo'

  union all
  -- 7. indicacao de CIO feita — so cota que tem vaga de mesa redonda
  -- pra indicar alguem
  select p.evento_id, 'patrocinador', p.id, null, p.empresa,
         'indicacao_cio_feita', p.created_at,
         (select min(i.created_at) from indicacoes i where i.patrocinador_id = p.id),
         null, null
  from patrocinadores p
  join cotas co on co.id = p.cota_id
  where p.status = 'ativo' and co.vagas_mesa_redonda > 0

  union all
  -- 8. ocupantes dos quartos preenchidos — ja tem data pronta
  select p.evento_id, 'patrocinador', p.id, null, p.empresa,
         'quartos_preenchidos', p.created_at, p.fechado_em,
         null, null
  from patrocinadores p
  join cotas co on co.id = p.cota_id
  where p.status = 'ativo' and (co.quartos_incluidos > 0 or p.quartos_extras_cota > 0)

  union all
  -- 9/10. convidados de mesa redonda e de jantar escolhidos — mesmo
  -- mecanismo (sessoes/sessao_convidados), so o tipo muda
  select s.evento_id, 'patrocinador', s.patrocinador_id, null, p.empresa,
         case s.tipo when 'mesa_redonda' then 'convidados_mesa_escolhidos'
                     else 'convidados_jantar_escolhidos' end,
         coalesce(s.escolha_liberada_em, s.created_at), s.escolha_encerrada_em,
         null, null
  from sessoes s
  join patrocinadores p on p.id = s.patrocinador_id
  where s.tipo in ('mesa_redonda','jantar') and p.status = 'ativo'

  union all
  -- 11. brindes definidos
  select p.evento_id, 'patrocinador', p.id, null, p.empresa,
         'brindes_definidos', p.created_at,
         (select min(b.created_at) from brindes b where b.patrocinador_id = p.id and b.vai_enviar),
         null, null
  from patrocinadores p
  where p.status = 'ativo'
;

create or replace view v_pendencias as
  select
    f.evento_id, f.publico, f.sujeito_id, f.sujeito_nome, f.sujeito_empresa,
    f.etapa_chave, ec.rotulo as etapa_rotulo, ec.ordem as etapa_ordem,
    f.aberta_em, f.concluida_em, f.vencimento, f.destinatario_email,
    case when f.concluida_em is not null then 'concluida' else 'pendente' end as status,
    case when f.concluida_em is not null then null
         else (current_date - f.aberta_em::date) end as dias_em_aberto,
    case
      when f.concluida_em is not null then 'ok'
      when f.etapa_chave = 'fatura_paga' then
        case
          when f.vencimento is null then 'ok'
          when current_date > f.vencimento then 'atrasado'
          when current_date >= f.vencimento - 5 then 'atencao'
          else 'ok'
        end
      when pe.dias_atencao is null then 'ok'
      when (current_date - f.aberta_em::date) >= pe.dias_atrasado then 'atrasado'
      when (current_date - f.aberta_em::date) >= pe.dias_atencao then 'atencao'
      else 'ok'
    end as nivel
  from v_pendencias_fatos f
  join etapas_config ec on ec.chave = f.etapa_chave
  join prazos_evento pe on pe.evento_id = f.evento_id and pe.etapa_chave = f.etapa_chave and pe.ativo;

-- ---------------------------------------------------------------------
-- leitura pro painel
-- ---------------------------------------------------------------------
create or replace function admin_pendencias_resumo(p_evento_slug text)
returns table (etapa_chave text, etapa_rotulo text, publico text,
               ok bigint, atencao bigint, atrasado bigint)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select v.etapa_chave, v.etapa_rotulo, v.publico,
           count(*) filter (where v.status = 'concluida' or v.nivel = 'ok'),
           count(*) filter (where v.status = 'pendente' and v.nivel = 'atencao'),
           count(*) filter (where v.status = 'pendente' and v.nivel = 'atrasado')
    from v_pendencias v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    group by v.etapa_chave, v.etapa_rotulo, v.publico, v.etapa_ordem
    order by v.publico, v.etapa_ordem;
end;
$$;

create or replace function admin_pendencias_lista(
  p_evento_slug text, p_etapa_chave text default null,
  p_nivel text default null, p_publico text default null,
  p_limite int default 200, p_offset int default 0
)
returns table (sujeito_id uuid, sujeito_nome text, sujeito_empresa text,
               publico text, etapa_chave text, etapa_rotulo text,
               status text, aberta_em timestamptz, concluida_em timestamptz,
               dias_em_aberto int, nivel text, destinatario_email text,
               total_geral bigint)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select v.sujeito_id, v.sujeito_nome, v.sujeito_empresa, v.publico,
           v.etapa_chave, v.etapa_rotulo, v.status, v.aberta_em, v.concluida_em,
           v.dias_em_aberto, v.nivel, v.destinatario_email,
           count(*) over ()
    from v_pendencias v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    where v.status = 'pendente'
      and (p_etapa_chave is null or v.etapa_chave = p_etapa_chave)
      and (p_nivel is null or v.nivel = p_nivel)
      and (p_publico is null or v.publico = p_publico)
    order by case v.nivel when 'atrasado' then 0 when 'atencao' then 1 else 2 end,
             v.dias_em_aberto desc nulls last
    limit greatest(coalesce(p_limite,200),1) offset greatest(coalesce(p_offset,0),0);
end;
$$;

-- ---------------------------------------------------------------------
-- prazos por evento
-- ---------------------------------------------------------------------
create or replace function admin_listar_prazos(p_evento_slug text)
returns table (etapa_chave text, etapa_rotulo text, publico text,
               dias_atencao int, dias_atrasado int, ativo boolean)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  return query
    select ec.chave, ec.rotulo, ec.publico, pe.dias_atencao, pe.dias_atrasado, pe.ativo
    from etapas_config ec
    join eventos e on e.slug = p_evento_slug
    left join prazos_evento pe on pe.evento_id = e.id and pe.etapa_chave = ec.chave
    order by ec.publico, ec.ordem;
end;
$$;

create or replace function admin_salvar_prazo(
  p_evento_slug text, p_etapa_chave text,
  p_dias_atencao int, p_dias_atrasado int, p_ativo boolean
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid;
begin
  perform _exige_admin();
  if p_dias_atencao is not null and p_dias_atrasado is not null
     and p_dias_atrasado < p_dias_atencao then
    raise exception 'O prazo de atrasado precisa ser maior ou igual ao de atenção'
      using errcode = '22023';
  end if;
  select id into v_evento from eventos where slug = p_evento_slug;
  insert into prazos_evento (evento_id, etapa_chave, dias_atencao, dias_atrasado, ativo)
  values (v_evento, p_etapa_chave, p_dias_atencao, p_dias_atrasado, coalesce(p_ativo,true))
  on conflict (evento_id, etapa_chave) do update
    set dias_atencao = excluded.dias_atencao,
        dias_atrasado = excluded.dias_atrasado,
        ativo = excluded.ativo;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function admin_pendencias_resumo(text) from public, anon;
revoke all on function admin_pendencias_lista(text,text,text,text,int,int) from public, anon;
revoke all on function admin_listar_prazos(text) from public, anon;
revoke all on function admin_salvar_prazo(text,text,int,int,boolean) from public, anon;
grant all on function admin_pendencias_resumo(text) to authenticated, service_role;
grant all on function admin_pendencias_lista(text,text,text,text,int,int) to authenticated, service_role;
grant all on function admin_listar_prazos(text) to authenticated, service_role;
grant all on function admin_salvar_prazo(text,text,int,int,boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- cobranca — sempre humana. As duas functions abaixo so preparam e so
-- enviam o que o organizador decidiu; nada dispara sozinho.
-- ---------------------------------------------------------------------
create or replace function admin_preparar_cobranca(
  p_sujeito_id uuid, p_etapa_chave text
) returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
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
$$;

create or replace function admin_disparar_cobranca(
  p_sujeito_id uuid, p_etapa_chave text,
  p_assunto text, p_corpo text, p_forcar boolean default false
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_row record;
  v_destinatarios text[];
  v_dest text;
  v_bloqueados int := 0;
  v_enviados int := 0;
  v_evento uuid;
begin
  -- disparar e comunicacao pra fora, com risco real de relacionamento
  -- (ver principio central do modulo) — staff ve e prepara, so admin dispara
  perform _exige_admin();

  select * into v_row from v_pendencias
   where sujeito_id = p_sujeito_id and etapa_chave = p_etapa_chave
   limit 1;
  if v_row is null then
    raise exception 'Pendência não encontrada' using errcode = 'P0002';
  end if;
  if v_row.status = 'concluida' then
    raise exception 'Essa etapa já foi concluída — não há pendência para cobrar'
      using errcode = '55000';
  end if;
  v_evento := v_row.evento_id;

  if v_row.publico = 'participante' then
    v_destinatarios := array[v_row.destinatario_email];
  else
    select array_agg(up.email) into v_destinatarios
    from usuarios_patrocinador up
    where up.patrocinador_id = p_sujeito_id and up.ativo;
  end if;

  foreach v_dest in array coalesce(v_destinatarios, array[]::text[]) loop
    if not p_forcar and exists (
      select 1 from notificacoes n
      where n.tipo = 'cobranca_' || p_etapa_chave
        and n.destinatario = v_dest
        and n.created_at > now() - interval '3 days'
    ) then
      v_bloqueados := v_bloqueados + 1;
      continue;
    end if;

    insert into notificacoes (evento_id, destinatario, tipo, assunto, corpo)
    values (v_evento, v_dest, 'cobranca_' || p_etapa_chave, p_assunto, p_corpo);
    v_enviados := v_enviados + 1;
  end loop;

  insert into auditoria (tabela, registro_id, acao, campo, valor_novo, usuario)
  values ('v_pendencias', p_sujeito_id, 'cobranca_enfileirada', p_etapa_chave,
          v_enviados || ' enfileirada(s), ' || v_bloqueados || ' bloqueada(s) por reenvio recente',
          auth.jwt() ->> 'email');

  return jsonb_build_object('ok', true, 'enfileiradas', v_enviados, 'bloqueadas', v_bloqueados);
end;
$$;

revoke all on function admin_preparar_cobranca(uuid,text) from public, anon;
revoke all on function admin_disparar_cobranca(uuid,text,text,text,boolean) from public, anon;
grant all on function admin_preparar_cobranca(uuid,text) to authenticated, service_role;
grant all on function admin_disparar_cobranca(uuid,text,text,text,boolean) to authenticated, service_role;
