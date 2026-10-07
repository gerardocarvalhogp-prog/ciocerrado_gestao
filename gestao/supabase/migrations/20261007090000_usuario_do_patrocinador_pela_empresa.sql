-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Usuario do patrocinador e achado pela EMPRESA nos seis lugares que
-- ainda procuravam pelo vinculo antigo.
--
-- Achado ao vivo pelo organizador em 07/10/2026: cadastrou um e-mail
-- valido pro patrocinador e "Preparar cobranca" respondeu "Nenhum e-mail
-- de contato ativo encontrado".
--
-- Desde 20260909100000 (patrocinador vira cadastro unico de empresa), o
-- login pertence a EMPRESA: admin_salvar_usuario_patro grava so
-- empresa_id, e usuarios_patrocinador.patrocinador_id ficou como
-- historico de quem originou o cadastro — vazio pra todo usuario criado
-- pela tela de hoje. meus_patrocinadores, admin_listar_patrocinadores e
-- admin_rel_lounge ja tinham migrado pra empresa_id; estes seis nao:
--
--   admin_preparar_cobranca / admin_disparar_cobranca — cobranca de
--       patrocinador nao achava destinatario
--   admin_listar_faturas      — Financeiro sem e-mail do patrocinador
--   admin_exportar_usuarios_app — usuario fora da planilha do app
--   v_etiquetas               — sem cracha
--   v_esperados               — fora da lista do check-in
--
-- Usuario cadastrado antes de 09/09 continua achado: o backfill daquela
-- migration preencheu empresa_id de todos.
--
-- Os testes 14 e 18 nao pegaram isso porque montavam o usuario de teste
-- com patrocinador_id preenchido (o jeito antigo). O teste 25 cadastra
-- como a tela cadastra hoje.
--
-- CREATE OR REPLACE VIEW reseta security_invoker — reafirmado no fim.
-- =====================================================================

set search_path = gestao, public;

CREATE OR REPLACE FUNCTION gestao.admin_preparar_cobranca(p_sujeito_id uuid, p_etapa_chave text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
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
    join patrocinadores pv on pv.empresa_id = up.empresa_id
    where pv.id = v_row.sujeito_id and up.ativo;
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
    when 'arquivos_enviados' then
      'Olá! Ainda faltam arquivos da sua cota (logo, banner, arte de revista, apresentação ou vídeo, conforme o pacote). Pode enviar pelo portal quando puder?'
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

CREATE OR REPLACE FUNCTION gestao.admin_disparar_cobranca(p_sujeito_id uuid, p_etapa_chave text, p_assunto text, p_corpo text, p_forcar boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_row record;
  v_destinatarios text[];
  v_dest text;
  v_bloqueados int := 0;
  v_enviados int := 0;
  v_evento uuid;
begin
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
    join patrocinadores pv on pv.empresa_id = up.empresa_id
    where pv.id = p_sujeito_id and up.ativo;
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

    insert into notificacoes (evento_id, destinatario, tipo, assunto, corpo, sujeito_id)
    values (v_evento, v_dest, 'cobranca_' || p_etapa_chave, p_assunto, p_corpo, p_sujeito_id);
    v_enviados := v_enviados + 1;
  end loop;

  insert into auditoria (tabela, registro_id, acao, campo, valor_novo, usuario)
  values ('v_pendencias', p_sujeito_id, 'cobranca_enfileirada', p_etapa_chave,
          v_enviados || ' enfileirada(s), ' || v_bloqueados || ' bloqueada(s) por reenvio recente',
          auth.jwt() ->> 'email');

  return jsonb_build_object('ok', true, 'enfileiradas', v_enviados, 'bloqueadas', v_bloqueados);
end;
$function$;

CREATE OR REPLACE FUNCTION gestao.admin_listar_faturas(p_evento_slug text, p_status text DEFAULT NULL::text, p_limite integer DEFAULT 500, p_offset integer DEFAULT 0)
 RETURNS TABLE(id uuid, tipo text, nome text, empresa text, email text, total numeric, status text, vencimento date, emitida_em timestamp with time zone, paga_em timestamp with time zone, forma_pagamento text, observacao text, itens text, total_geral bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select f.id,
           case when f.participante_id is not null then 'participante'
                else 'patrocinador' end,
           coalesce(g.nome, p.empresa),
           coalesce(g.empresa, p.empresa),
           coalesce(g.email, (select u.email from usuarios_patrocinador u
                              where u.empresa_id = p.empresa_id and u.ativo
                              order by u.created_at limit 1)),
           f.total, f.status, f.vencimento,
           f.emitida_em, f.paga_em, f.forma_pagamento, f.observacao,
           coalesce((select string_agg(fi.descricao || ' ×' || fi.quantidade, ', '
                                       order by fi.descricao)
                     from fatura_itens fi where fi.fatura_id = f.id), '—'),
           count(*) over ()
    from faturas f
    join eventos e on e.id = f.evento_id and e.slug = p_evento_slug
    left join participantes pa on pa.id = f.participante_id
    left join gestores g on g.id = pa.gestor_id
    left join patrocinadores p on p.id = f.patrocinador_id
    where f.status <> 'cancelada'
      and f.total > 0
      and (p_status is null or f.status = p_status)
    order by (f.status = 'paga'), f.total desc
    limit p_limite offset p_offset;
end;
$function$;

CREATE OR REPLACE FUNCTION gestao.admin_exportar_usuarios_app(p_evento_slug text)
 RETURNS TABLE(name text, cargo text, email text, cidade text, estado text, linkedin text, segmento text, telefone text, empresa_id integer, ramo_atividade text, evento_id integer, mapeado boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v_evento uuid; v_id_app integer;
begin
  perform _exige_admin();
  select id, id_app into v_evento, v_id_app from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;

  return query
    select g.nome, g.cargo, g.email, g.cidade, g.estado, g.linkedin,
           g.segmento, g.telefone, m.empresa_id_app, g.segmento, v_id_app,
           (g.empresa_id is null or m.empresa_id_app is not null)
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    left join mapa_empresa_app m on m.evento_id = v_evento and m.empresa_id = g.empresa_id
    where pa.evento_id = v_evento and pa.status = 'aprovado'

    union all

    select coalesce(up.nome, split_part(up.email,'@',1)), null, up.email,
           p.cidade, p.estado, null, p.segmento, up.telefone,
           m.empresa_id_app, p.segmento, v_id_app,
           (m.empresa_id_app is not null)
    from usuarios_patrocinador up
    join patrocinadores p on p.empresa_id = up.empresa_id
    left join mapa_empresa_app m on m.evento_id = v_evento and m.patrocinador_id = p.id
    where p.evento_id = v_evento and up.ativo and p.status = 'ativo';
end;
$function$;

CREATE OR REPLACE VIEW gestao.v_etiquetas AS
 SELECT r.evento_id,
    ('ocupante:'::text || (o.id)::text) AS pessoa_key,
    q.numero AS apto,
    o.nome,
    COALESCE(p.empresa, g.empresa, r.rotulo) AS empresa,
        CASE
            WHEN ((o.data_nascimento IS NOT NULL) AND (age((o.data_nascimento)::timestamp without time zone) < '21 years'::interval)) THEN 'S/CRACHA'::text
            ELSE COALESCE(o.categoria_cracha,
            CASE
                WHEN (r.patrocinador_id IS NOT NULL) THEN 'PATROCINADOR'::text
                WHEN (o.tipo = 'titular'::text) THEN 'PROTAGONISTA'::text
                ELSE 'FAMILIAR'::text
            END)
        END AS categoria,
    'quarto'::text AS origem
   FROM (((((gestao.ocupantes o
     JOIN gestao.reservas r ON (((r.id = o.reserva_id) AND (r.status <> 'cancelado'::text))))
     LEFT JOIN gestao.quartos q ON ((q.id = r.quarto_id)))
     LEFT JOIN gestao.patrocinadores p ON ((p.id = r.patrocinador_id)))
     LEFT JOIN gestao.participantes pa ON ((pa.id = r.participante_id)))
     LEFT JOIN gestao.gestores g ON ((g.id = pa.gestor_id)))
UNION ALL
 SELECT pa.evento_id,
    ('participante:'::text || (pa.id)::text) AS pessoa_key,
    NULL::text AS apto,
    g.nome,
    g.empresa,
    'PROTAGONISTA'::text AS categoria,
    'inscricao'::text AS origem
   FROM (gestao.participantes pa
     JOIN gestao.gestores g ON ((g.id = pa.gestor_id)))
  WHERE ((pa.status = 'aprovado'::text) AND (NOT (EXISTS ( SELECT 1
           FROM gestao.reservas r
          WHERE ((r.participante_id = pa.id) AND (r.status <> 'cancelado'::text))))))
UNION ALL
 SELECT p.evento_id,
    ('usuario_patro:'::text || (u.id)::text) AS pessoa_key,
    NULL::text AS apto,
    COALESCE(u.nome, split_part(u.email, '@'::text, 1)) AS nome,
    p.empresa,
    'PATROCINADOR'::text AS categoria,
    'patrocinador'::text AS origem
   FROM (gestao.usuarios_patrocinador u
     JOIN gestao.patrocinadores p ON ((p.empresa_id = u.empresa_id)))
  WHERE (u.ativo AND (p.status = 'ativo'::text) AND (NOT (EXISTS ( SELECT 1
           FROM gestao.reservas r
          WHERE ((r.patrocinador_id = p.id) AND (r.status <> 'cancelado'::text))))));

CREATE OR REPLACE VIEW gestao.v_esperados AS
 SELECT r.evento_id,
    ('ocupante:'::text || (o.id)::text) AS pessoa_key,
    o.nome,
    COALESCE(p.empresa, g.empresa) AS empresa,
    COALESCE(o.categoria_cracha,
        CASE
            WHEN (r.patrocinador_id IS NOT NULL) THEN 'PATROCINADOR'::text
            WHEN (o.tipo = 'titular'::text) THEN 'PROTAGONISTA'::text
            ELSE 'FAMILIAR'::text
        END) AS categoria,
    q.numero AS quarto,
    r.patrocinador_id,
    COALESCE(o.email, g.email) AS email
   FROM (((((gestao.ocupantes o
     JOIN gestao.reservas r ON (((r.id = o.reserva_id) AND (r.status <> 'cancelado'::text))))
     LEFT JOIN gestao.quartos q ON ((q.id = r.quarto_id)))
     LEFT JOIN gestao.patrocinadores p ON ((p.id = r.patrocinador_id)))
     LEFT JOIN gestao.participantes pa ON ((pa.id = r.participante_id)))
     LEFT JOIN gestao.gestores g ON ((g.id = pa.gestor_id)))
UNION ALL
 SELECT pa.evento_id,
    ('participante:'::text || (pa.id)::text) AS pessoa_key,
    g.nome,
    g.empresa,
    COALESCE(NULLIF(g.perfil, ''::text), 'PROTAGONISTA'::text) AS categoria,
    NULL::text AS quarto,
    NULL::uuid AS patrocinador_id,
    g.email
   FROM (gestao.participantes pa
     JOIN gestao.gestores g ON ((g.id = pa.gestor_id)))
  WHERE ((pa.status = 'aprovado'::text) AND (NOT (EXISTS ( SELECT 1
           FROM gestao.reservas r
          WHERE ((r.participante_id = pa.id) AND (r.status <> 'cancelado'::text))))))
UNION ALL
 SELECT p.evento_id,
    ('usuario_patro:'::text || (u.id)::text) AS pessoa_key,
    COALESCE(u.nome, split_part(u.email, '@'::text, 1)) AS nome,
    p.empresa,
    'PATROCINADOR'::text AS categoria,
    NULL::text AS quarto,
    p.id AS patrocinador_id,
    u.email
   FROM (gestao.usuarios_patrocinador u
     JOIN gestao.patrocinadores p ON ((p.empresa_id = u.empresa_id)))
  WHERE (u.ativo AND (p.status = 'ativo'::text) AND (NOT (EXISTS ( SELECT 1
           FROM gestao.reservas r
          WHERE ((r.patrocinador_id = p.id) AND (r.status <> 'cancelado'::text))))));

alter view v_etiquetas set (security_invoker = true);
alter view v_esperados set (security_invoker = true);
