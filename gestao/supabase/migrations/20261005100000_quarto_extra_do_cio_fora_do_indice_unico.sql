-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- CIO com reserva principal volta a conseguir comprar quarto extra.
--
-- Achado do teste 13 (05/10/2026), decisao do organizador: corrigir.
-- 20260918090000 criou o indice unico reservas_participante_ativa_uk
-- (UMA reserva ativa por participante) numa epoca em que o CIO nao
-- comprava quarto extra — 20260909120000 tinha tirado isso. Em
-- 20260930140000 a compra voltou (part_comprar_quarto, so do pool
-- avulso), mas o indice ficou: todo CIO que ja tinha a reserva da
-- inscricao recebia "duplicate key" ao comprar. Na pratica, ninguem
-- conseguia.
--
-- O invariante que o indice protegia continua valendo, so que pra
-- reserva PRINCIPAL: uma por participante, contra o duplo clique em
-- part_salvar_rooming. Quarto extra (origem='extra') fica fora do indice
-- — pode ter quantos o CIO comprar.
--
-- Com mais de uma reserva ativa possivel, todo lugar que le "a reserva
-- do CIO" precisa dizer qual: a principal (origem <> 'extra'). Sem isso,
-- a busca pega uma arbitraria ou a juncao duplica a linha do CIO:
--   _garantir_reserva       — devolveria o quarto extra como "a" reserva
--   part_meu_status          — rooming_liberado/status de uma qualquer
--   part_listar_rooming      — misturaria quem dorme no extra no
--                              formulario da hospedagem principal
--   v_painel_participantes   — CIO aparece duas vezes no painel
--   v_pendencias_fatos       — "hospedagem preenchida" duplicada
-- _recalcular_fatura_participante ja filtrava (origem <> 'extra') e
-- cobra o extra a parte; nao muda.
--
-- CREATE OR REPLACE VIEW reseta security_invoker (achado em
-- 20260910090000) — reafirmado no fim, mesmo padrao.
-- =====================================================================

set search_path = gestao, public;

drop index if exists reservas_participante_ativa_uk;
create unique index reservas_participante_ativa_uk
  on reservas (participante_id)
  where status <> 'cancelado' and participante_id is not null and origem <> 'extra';

CREATE OR REPLACE FUNCTION gestao._garantir_reserva(p_participante_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v_res uuid; v_evento uuid;
begin
  -- trava a linha do participante ate o fim da transacao chamadora —
  -- duas chamadas concorrentes pro mesmo participante serializam aqui,
  -- a segunda so' prossegue depois que a primeira ja' commitou a
  -- reserva (e entao acha a reserva no SELECT abaixo, nao cria outra)
  perform 1 from participantes where id = p_participante_id for update;

  select id into v_res from reservas
   where participante_id = p_participante_id and status <> 'cancelado'
     and origem <> 'extra';

  if v_res is not null then return v_res; end if;

  select evento_id into v_evento from participantes where id = p_participante_id;

  insert into reservas (evento_id, participante_id, rotulo, tipo, origem, status)
  values (v_evento, p_participante_id, 'Hospedagem', 'duplo', 'inscricao', 'rascunho')
  returning id into v_res;

  return v_res;
end;
$function$;

CREATE OR REPLACE FUNCTION gestao.part_meu_status(p_evento_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_part uuid;
  v_out  jsonb;
begin
  v_part := _meu_participante(p_evento_slug);

  if v_part is null then
    return jsonb_build_object('inscrito', false);
  end if;

  select jsonb_build_object(
    'inscrito',          true,
    'participante_id',   pa.id,
    'nome',              g.nome,
    'empresa',           g.empresa,
    'status_inscricao',  pa.status,
    'status_contrato',   coalesce(ct.status, 'nao_enviado'),
    'contrato_url',      ct.autentique_url,
    -- rooming so abre com inscricao aprovada E contrato assinado
    'rooming_liberado',  (pa.status = 'aprovado'
                          and coalesce(ct.status,'') = 'assinado'),
    'prazo_rooming',     e.prazo_rooming,
    'prazo_contrato',    e.prazo_contrato,
    'reserva_id',        r.id,
    'status_rooming',    coalesce(r.status, 'nao_iniciado')
  ) into v_out
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  join eventos  e on e.id = pa.evento_id
  left join contratos ct on ct.participante_id = pa.id
  left join reservas  r  on r.participante_id = pa.id and r.status <> 'cancelado'
                         and r.origem <> 'extra'
  where pa.id = v_part;

  return v_out;
end;
$function$;

CREATE OR REPLACE FUNCTION gestao.part_listar_rooming(p_evento_slug text)
 RETURNS TABLE(id uuid, nome text, cpf text, data_nascimento date, tipo text, usa_transfer boolean, transfer_origem text, dificuldade_mobilidade boolean, tem_alergia boolean, alergia_detalhe text, precisa_berco boolean, observacoes text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v_part uuid;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then return; end if;

  return query
    select o.id, o.nome, o.cpf, o.data_nascimento, o.tipo, o.usa_transfer,
           o.transfer_origem, o.dificuldade_mobilidade, o.tem_alergia,
           o.alergia_detalhe, o.precisa_berco, o.observacoes
    from ocupantes o
    join reservas r on r.id = o.reserva_id
    where r.participante_id = v_part and r.status <> 'cancelado' and r.origem <> 'extra'
    order by (o.tipo = 'titular') desc, o.created_at;
end;
$function$;

CREATE OR REPLACE VIEW gestao.v_painel_participantes AS
 SELECT pa.evento_id,
    pa.id AS participante_id,
    g.nome,
    g.empresa,
    g.email,
    pa.status AS status_inscricao,
    COALESCE(ct.status, 'nao_enviado'::text) AS status_contrato,
        CASE
            WHEN (r.id IS NULL) THEN 'nao_iniciado'::text
            WHEN (r.status = 'completo'::text) THEN 'completo'::text
            ELSE 'parcial'::text
        END AS status_rooming,
    r.usa_transfer,
    q.numero AS quarto,
    ct.autentique_url
   FROM ((((gestao.participantes pa
     JOIN gestao.gestores g ON ((g.id = pa.gestor_id)))
     LEFT JOIN gestao.contratos ct ON ((ct.participante_id = pa.id)))
     LEFT JOIN gestao.reservas r ON (((r.participante_id = pa.id) AND (r.status <> 'cancelado'::text) AND (r.origem <> 'extra'::text))))
     LEFT JOIN gestao.quartos q ON ((q.id = r.quarto_id)));

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
              WHERE ((u.patrocinador_id = p.id) AND (u.tipo = 'logo'::text))) >= GREATEST(COALESCE(co.upload_logo_qtd, 0), 0)) AND (( SELECT count(DISTINCT u.tipo) AS count
               FROM gestao.patrocinador_uploads u
              WHERE ((u.patrocinador_id = p.id) AND (u.tipo = ANY (v_req.tipos_bool)))) >= COALESCE(array_length(v_req.tipos_bool, 1), 0))) THEN ( SELECT max(u.enviado_em) AS max
               FROM gestao.patrocinador_uploads u
              WHERE ((u.patrocinador_id = p.id) AND ((u.tipo = ANY (v_req.tipos_bool)) OR (u.tipo = 'logo'::text))))
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

alter view v_painel_participantes set (security_invoker = true);
alter view v_pendencias_fatos set (security_invoker = true);
