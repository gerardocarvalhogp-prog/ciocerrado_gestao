-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Arquivos do patrocinador: o banco confere a cota, e arquivo rejeitado
-- nao conta como enviado.
--
-- Achados do teste 17 (05/10/2026), decisao do organizador: corrigir.
--
-- 1. patro_registrar_upload aceitava qualquer um dos 5 tipos e qualquer
--    ordem — so a tela deixava de oferecer o slot. Pelo CLAUDE.md, regra
--    fica na funcao, nao no front. Agora recusa tipo que a cota nao pede,
--    logo alem de cotas.upload_logo_qtd, e ordem <> 1 nos outros tipos —
--    exatamente os slots que patro_meus_uploads ja mostra.
--
-- 2. A pendencia "arquivos_enviados" (v_pendencias_fatos) contava a
--    LINHA do upload, nao o status dela: logo/banner rejeitado pelo admin
--    seguia fechando a pendencia, e ninguem era cobrado de mandar outro.
--    As tres subconsultas da etapa passam a ignorar status 'rejeitado'.
--    Reenviar volta a linha pra 'enviado' (patro_registrar_upload ja
--    fazia isso), e a pendencia fecha de novo.
--
-- CREATE OR REPLACE VIEW reseta security_invoker — reafirmado no fim.
-- =====================================================================

set search_path = gestao, public;

CREATE OR REPLACE FUNCTION gestao.patro_registrar_upload(p_patrocinador_id uuid, p_tipo text, p_storage_path text, p_nome_arquivo text, p_tamanho_bytes bigint DEFAULT NULL::bigint, p_ordem integer DEFAULT 1, p_largura integer DEFAULT NULL::integer, p_altura integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v_id uuid; v_cota record; v_pede boolean;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  if p_tipo not in ('logo','banner','arte_revista','apresentacao','video') then
    raise exception 'Tipo de arquivo invalido: %', p_tipo using errcode = '22023';
  end if;
  if coalesce(p_ordem,1) < 1 then
    raise exception 'Ordem invalida: %', p_ordem using errcode = '22023';
  end if;

  -- a cota decide o que pede (mesmos slots de patro_meus_uploads): N
  -- logos, e banner/arte/apresentacao/video por boolean, sempre ordem 1
  select c.upload_logo_qtd, c.upload_banner, c.upload_arte_revista,
         c.upload_apresentacao, c.upload_video
    into v_cota
  from patrocinadores p join cotas c on c.id = p.cota_id
  where p.id = p_patrocinador_id;

  if p_tipo = 'logo' then
    if coalesce(p_ordem,1) > coalesce(v_cota.upload_logo_qtd, 0) then
      raise exception 'Sua cota pede % logo(s); nao ha espaco pro logo %',
        coalesce(v_cota.upload_logo_qtd, 0), coalesce(p_ordem,1) using errcode = '22023';
    end if;
  else
    if coalesce(p_ordem,1) <> 1 then
      raise exception 'So o logo aceita mais de um arquivo' using errcode = '22023';
    end if;
    v_pede := case p_tipo
      when 'banner'       then v_cota.upload_banner
      when 'arte_revista' then v_cota.upload_arte_revista
      when 'apresentacao' then v_cota.upload_apresentacao
      when 'video'        then v_cota.upload_video end;
    if not coalesce(v_pede, false) then
      raise exception 'Sua cota nao inclui o envio de %', p_tipo using errcode = '22023';
    end if;
  end if;

  insert into patrocinador_uploads (patrocinador_id, tipo, ordem, storage_path, nome_arquivo,
                                    tamanho_bytes, largura, altura, status, enviado_por)
  values (p_patrocinador_id, p_tipo, coalesce(p_ordem,1), p_storage_path, p_nome_arquivo,
          p_tamanho_bytes, p_largura, p_altura, 'enviado', auth.jwt() ->> 'email')
  on conflict (patrocinador_id, tipo, ordem) do update set
    storage_path = excluded.storage_path,
    nome_arquivo = excluded.nome_arquivo,
    tamanho_bytes = excluded.tamanho_bytes,
    largura = excluded.largura,
    altura = excluded.altura,
    status = 'enviado',
    observacao_admin = null,
    enviado_em = now(),
    enviado_por = excluded.enviado_por
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$function$;

CREATE OR REPLACE VIEW gestao.v_pendencias_fatos AS
 SELECT pa.evento_id,
    'participante'::text AS publico,
    pa.id AS sujeito_id,
    g.nome AS sujeito_nome,
    g.empresa AS sujeito_empresa,
    'inscricao_aprovada'::text AS etapa_chave,
    pa.created_at AS aberta_em,
    pa.aprovado_em AS concluida_em,
    NULL::date AS vencimento,
    g.email AS destinatario_email
   FROM (gestao.participantes pa
     JOIN gestao.gestores g ON ((g.id = pa.gestor_id)))
  WHERE (pa.status <> ALL (ARRAY['recusado'::text, 'cancelado'::text]))
UNION ALL
 SELECT pa.evento_id,
    'participante'::text AS publico,
    pa.id AS sujeito_id,
    g.nome AS sujeito_nome,
    g.empresa AS sujeito_empresa,
    'contrato_assinado'::text AS etapa_chave,
    pa.aprovado_em AS aberta_em,
    c.assinado_em AS concluida_em,
    NULL::date AS vencimento,
    g.email AS destinatario_email
   FROM ((gestao.participantes pa
     JOIN gestao.gestores g ON ((g.id = pa.gestor_id)))
     LEFT JOIN gestao.contratos c ON ((c.participante_id = pa.id)))
  WHERE ((pa.status = 'aprovado'::text) AND ((c.status IS NULL) OR (c.status <> ALL (ARRAY['recusado'::text, 'cancelado'::text]))))
UNION ALL
 SELECT pa.evento_id,
    'participante'::text AS publico,
    pa.id AS sujeito_id,
    g.nome AS sujeito_nome,
    g.empresa AS sujeito_empresa,
    'hospedagem_preenchida'::text AS etapa_chave,
    c.assinado_em AS aberta_em,
    r.completo_em AS concluida_em,
    NULL::date AS vencimento,
    g.email AS destinatario_email
   FROM (((gestao.participantes pa
     JOIN gestao.gestores g ON ((g.id = pa.gestor_id)))
     JOIN gestao.contratos c ON (((c.participante_id = pa.id) AND (c.status = 'assinado'::text))))
     LEFT JOIN gestao.reservas r ON (((r.participante_id = pa.id) AND (r.status <> 'cancelado'::text) AND (r.origem <> 'extra'::text))))
UNION ALL
 SELECT f.evento_id,
    'participante'::text AS publico,
    f.participante_id AS sujeito_id,
    g.nome AS sujeito_nome,
    g.empresa AS sujeito_empresa,
    'fatura_paga'::text AS etapa_chave,
    f.created_at AS aberta_em,
    f.paga_em AS concluida_em,
    f.vencimento,
    g.email AS destinatario_email
   FROM ((gestao.faturas f
     JOIN gestao.participantes pa ON ((pa.id = f.participante_id)))
     JOIN gestao.gestores g ON ((g.id = pa.gestor_id)))
  WHERE ((f.status <> 'cancelada'::text) AND (f.total > (0)::numeric))
UNION ALL
 SELECT s.evento_id,
    'participante'::text AS publico,
    sc.participante_id AS sujeito_id,
    g.nome AS sujeito_nome,
    g.empresa AS sujeito_empresa,
    'presenca_confirmada'::text AS etapa_chave,
    sc.created_at AS aberta_em,
    sc.resposta_em AS concluida_em,
    NULL::date AS vencimento,
    g.email AS destinatario_email
   FROM (((gestao.sessao_convidados sc
     JOIN gestao.sessoes s ON ((s.id = sc.sessao_id)))
     JOIN gestao.participantes pa ON ((pa.id = sc.participante_id)))
     JOIN gestao.gestores g ON ((g.id = pa.gestor_id)))
  WHERE (sc.status = 'confirmado'::text)
UNION ALL
 SELECT p.evento_id,
    'patrocinador'::text AS publico,
    p.id AS sujeito_id,
    NULL::text AS sujeito_nome,
    p.empresa AS sujeito_empresa,
    'contrato_patrocinio_assinado'::text AS etapa_chave,
    p.created_at AS aberta_em,
    c.assinado_em AS concluida_em,
    NULL::date AS vencimento,
    NULL::text AS destinatario_email
   FROM (gestao.patrocinadores p
     LEFT JOIN gestao.contratos c ON ((c.patrocinador_id = p.id)))
  WHERE (p.status = 'ativo'::text)
UNION ALL
 SELECT p.evento_id,
    'patrocinador'::text AS publico,
    p.id AS sujeito_id,
    NULL::text AS sujeito_nome,
    p.empresa AS sujeito_empresa,
    'indicacao_cio_feita'::text AS etapa_chave,
    p.created_at AS aberta_em,
    ( SELECT min(i.created_at) AS min
           FROM gestao.indicacoes i
          WHERE (i.patrocinador_id = p.id)) AS concluida_em,
    NULL::date AS vencimento,
    NULL::text AS destinatario_email
   FROM (gestao.patrocinadores p
     JOIN gestao.cotas co ON ((co.id = p.cota_id)))
  WHERE ((p.status = 'ativo'::text) AND (co.vagas_mesa_redonda > 0))
UNION ALL
 SELECT p.evento_id,
    'patrocinador'::text AS publico,
    p.id AS sujeito_id,
    NULL::text AS sujeito_nome,
    p.empresa AS sujeito_empresa,
    'quartos_preenchidos'::text AS etapa_chave,
    p.created_at AS aberta_em,
    p.fechado_em AS concluida_em,
    NULL::date AS vencimento,
    NULL::text AS destinatario_email
   FROM (gestao.patrocinadores p
     JOIN gestao.cotas co ON ((co.id = p.cota_id)))
  WHERE ((p.status = 'ativo'::text) AND ((co.quartos_incluidos > 0) OR (p.quartos_extras_cota > 0)))
UNION ALL
 SELECT s.evento_id,
    'patrocinador'::text AS publico,
    s.patrocinador_id AS sujeito_id,
    NULL::text AS sujeito_nome,
    p.empresa AS sujeito_empresa,
        CASE s.tipo
            WHEN 'mesa_redonda'::text THEN 'convidados_mesa_escolhidos'::text
            ELSE 'convidados_jantar_escolhidos'::text
        END AS etapa_chave,
    COALESCE(s.escolha_liberada_em, s.created_at) AS aberta_em,
    s.escolha_encerrada_em AS concluida_em,
    NULL::date AS vencimento,
    NULL::text AS destinatario_email
   FROM (gestao.sessoes s
     JOIN gestao.patrocinadores p ON ((p.id = s.patrocinador_id)))
  WHERE ((s.tipo = ANY (ARRAY['mesa_redonda'::text, 'jantar'::text])) AND (p.status = 'ativo'::text))
UNION ALL
 SELECT p.evento_id,
    'patrocinador'::text AS publico,
    p.id AS sujeito_id,
    NULL::text AS sujeito_nome,
    p.empresa AS sujeito_empresa,
    'brindes_definidos'::text AS etapa_chave,
    p.created_at AS aberta_em,
    ( SELECT min(b.created_at) AS min
           FROM gestao.brindes b
          WHERE ((b.patrocinador_id = p.id) AND b.vai_enviar)) AS concluida_em,
    NULL::date AS vencimento,
    NULL::text AS destinatario_email
   FROM gestao.patrocinadores p
  WHERE (p.status = 'ativo'::text)
UNION ALL
 SELECT p.evento_id,
    'patrocinador'::text AS publico,
    p.id AS sujeito_id,
    NULL::text AS sujeito_nome,
    p.empresa AS sujeito_empresa,
    'arquivos_enviados'::text AS etapa_chave,
    p.created_at AS aberta_em,
        CASE
            WHEN ((( SELECT count(*) AS count
               FROM gestao.patrocinador_uploads u
              WHERE ((u.patrocinador_id = p.id) AND (u.tipo = 'logo'::text) AND (u.status <> 'rejeitado'::text))) >= GREATEST(COALESCE(co.upload_logo_qtd, 0), 0)) AND (( SELECT count(DISTINCT u.tipo) AS count
               FROM gestao.patrocinador_uploads u
              WHERE ((u.patrocinador_id = p.id) AND (u.tipo = ANY (v_req.tipos_bool)) AND (u.status <> 'rejeitado'::text))) >= COALESCE(array_length(v_req.tipos_bool, 1), 0))) THEN ( SELECT max(u.enviado_em) AS max
               FROM gestao.patrocinador_uploads u
              WHERE ((u.patrocinador_id = p.id) AND ((u.tipo = ANY (v_req.tipos_bool)) OR (u.tipo = 'logo'::text)) AND (u.status <> 'rejeitado'::text)))
            ELSE NULL::timestamp with time zone
        END AS concluida_em,
    COALESCE(co.prazo_upload, e2.prazo_upload_padrao) AS vencimento,
    NULL::text AS destinatario_email
   FROM (((gestao.patrocinadores p
     JOIN gestao.cotas co ON ((co.id = p.cota_id)))
     JOIN gestao.eventos e2 ON ((e2.id = p.evento_id)))
     CROSS JOIN LATERAL ( SELECT array_remove(ARRAY[
                CASE
                    WHEN co.upload_banner THEN 'banner'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN co.upload_arte_revista THEN 'arte_revista'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN co.upload_apresentacao THEN 'apresentacao'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN co.upload_video THEN 'video'::text
                    ELSE NULL::text
                END], NULL::text) AS tipos_bool) v_req)
  WHERE ((p.status = 'ativo'::text) AND ((COALESCE(co.upload_logo_qtd, 0) > 0) OR (COALESCE(array_length(v_req.tipos_bool, 1), 0) > 0)));

alter view v_pendencias_fatos set (security_invoker = true);
