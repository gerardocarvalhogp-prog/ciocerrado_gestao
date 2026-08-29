-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Leitura das abas exclusivas de admin passa a exigir admin de verdade
-- Retorno de QA (Cowork, Rodada 2, 30/08/2026)
--
-- O menu ja escondia Equipe/Financeiro/Cadastro/etc do staff (achado
-- anterior), mas so na tela: as 28 functions de leitura por tras dessas
-- abas continuavam com _exige_staff(), a mesma trava fraca de sempre.
-- Um staff que soubesse o link direto (#equipe, #financeiro...) via
-- e-mail de admin, roster da equipe, fatura com valor e e-mail do
-- participante. As escritas (salvar/remover) ja exigiam admin desde o
-- baseline — o buraco era so leitura. CLAUDE.md e explicito: staff
-- opera "check-in, etiquetas, alocacao e relatorios", nada disso.
--
-- set search_path already embutido em cada function pelo
-- pg_get_functiondef; nao precisa repetir aqui.
-- =====================================================================

CREATE OR REPLACE FUNCTION gestao.admin_associar_gestor_empresa(p_gestor_id uuid, p_empresa_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  update gestores set empresa_id = p_empresa_id where id = p_gestor_id;
  if not found then
    raise exception 'Gestor nao encontrado' using errcode='P0002';
  end if;
  return jsonb_build_object('ok', true);
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_empresas_da_rodada(p_rodada text)
 RETURNS TABLE(empresa text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select distinct pr.empresa
    from prospeccoes pr
    where coalesce(pr.sessao_id::text, 'sem-sessao-' || pr.evento_id::text) = p_rodada
      and pr.status in ('aprovado','convidado')
      and coalesce(trim(pr.empresa),'') <> '';
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_fatura_itens(p_fatura_id uuid)
 RETURNS TABLE(descricao text, quantidade integer, valor_unit numeric, valor_total numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select fi.descricao, fi.quantidade, fi.valor_unit, fi.valor_total
    from fatura_itens fi where fi.fatura_id = p_fatura_id
    order by fi.descricao;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_filtros_gestores()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v jsonb;
begin
  perform _exige_admin();
  -- devolve valor e contagem: saber que GOVERNO tem 275 e AGRO 191
  -- ajuda a escolher, e denuncia lixo de cadastro com contagem 1
  select jsonb_build_object(
    'perfis',    (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by n desc, v),'[]'::jsonb)
                    from (select perfil v, count(*) n from gestores
                           where coalesce(trim(perfil),'') <> '' group by 1) a),
    -- segmento vem da lista, nao do que esta gravado: item sem ninguem
    -- ainda precisa aparecer, senao nunca da para filtrar por ele
    'segmentos', (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by codigo),'[]'::jsonb)
                    from (select s.codigo, s.nome v,
                                 (select count(*) from gestores g
                                   where g.segmento = s.nome) n
                            from segmentos s where s.ativo) b),
    'estados',   (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by n desc, v),'[]'::jsonb)
                    from (select upper(estado) v, count(*) n from gestores
                           where coalesce(trim(estado),'') <> '' group by 1) c),
    'cidades',   (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by n desc, v),'[]'::jsonb)
                    from (select cidade v, count(*) n from gestores
                           where coalesce(trim(cidade),'') <> '' group by 1) d),
    'posicoes',  (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by v),'[]'::jsonb)
                    from (select posicao_gestor v, count(*) n from gestores
                           where coalesce(trim(posicao_gestor),'') <> '' group by 1) e)
  ) into v;
  return v;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_financeiro_resumo(p_evento_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_aberto numeric(12,2); v_pago numeric(12,2);
  v_n_aberto int; v_n_pago int; v_vencido int;
begin
  perform _exige_admin();

  select coalesce(sum(f.total) filter (where f.status <> 'paga'),0),
         coalesce(sum(f.total) filter (where f.status = 'paga'),0),
         count(*) filter (where f.status <> 'paga'),
         count(*) filter (where f.status = 'paga'),
         count(*) filter (where f.status <> 'paga'
                            and f.vencimento is not null
                            and f.vencimento < current_date)
    into v_aberto, v_pago, v_n_aberto, v_n_pago, v_vencido
  from faturas f
  join eventos e on e.id = f.evento_id and e.slug = p_evento_slug
  where f.status <> 'cancelada';

  return jsonb_build_object(
    'em_aberto', v_aberto, 'recebido', v_pago,
    'total', v_aberto + v_pago,
    'qtd_aberto', v_n_aberto, 'qtd_pago', v_n_pago,
    'vencidas', v_vencido);
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_listar_categorias_quarto(p_evento_slug text)
 RETURNS TABLE(codigo text, nome text, descricao text, capacidade integer, tipo text, quartos bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select c.codigo, c.nome, c.descricao, c.capacidade, c.tipo,
           (select count(*) from quartos q
             where q.evento_id = c.evento_id
               and upper(q.categoria) = upper(c.codigo))
    from categorias_quarto c
    join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
    order by c.codigo;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_listar_cotas(p_evento_slug text)
 RETURNS TABLE(id uuid, nome text, ordem_prioridade integer, quartos jsonb, total_quartos bigint, vagas_mesa_redonda integer, tem_reuniao_exclusiva boolean, tem_jantar boolean, patrocinadores bigint, lista_patrocinadores jsonb, prazo_indicacao date, janela_horas integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select c.id, c.nome, c.ordem_prioridade,
           coalesce((select jsonb_object_agg(cq.tipo, cq.quantidade)
                     from cota_quartos cq where cq.cota_id = c.id
                       and cq.quantidade > 0), '{}'::jsonb),
           coalesce((select sum(cq.quantidade) from cota_quartos cq
                     where cq.cota_id = c.id), 0),
           c.vagas_mesa_redonda, c.tem_reuniao_exclusiva, c.tem_jantar,
           (select count(*) from patrocinadores p where p.cota_id = c.id),
           coalesce((select jsonb_agg(jsonb_build_object(
                       'id', p.id, 'empresa', p.empresa) order by p.empresa)
                     from patrocinadores p
                     where p.cota_id = c.id and p.status = 'ativo'), '[]'::jsonb),
           c.prazo_indicacao, c.janela_horas
    from cotas c
    join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_listar_empresas(p_busca text DEFAULT NULL::text, p_segmentos text[] DEFAULT NULL::text[], p_cidades text[] DEFAULT NULL::text[], p_estados text[] DEFAULT NULL::text[], p_perfis text[] DEFAULT NULL::text[], p_so_com_gestores boolean DEFAULT false, p_limite integer DEFAULT 500, p_offset integer DEFAULT 0)
 RETURNS TABLE(id uuid, nome text, cnpj text, site text, segmento text, cidade text, estado text, qtd_gestores bigint, total_geral bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    with base as (
      select e.id, e.nome, e.cnpj, e.site, e.segmento, e.cidade, e.estado,
             (select count(*) from gestores g where g.empresa_id = e.id) as qtd
      from empresas e
      where (p_busca is null or
             unaccent('unaccent', lower(e.nome))
               like '%' || unaccent('unaccent', lower(p_busca)) || '%')
        and (p_segmentos is null or cardinality(p_segmentos) = 0
             or e.segmento = any(p_segmentos)
             or exists (select 1 from gestores g
                         where g.empresa_id = e.id and g.segmento = any(p_segmentos)))
        and (p_cidades is null or cardinality(p_cidades) = 0
             or unaccent('unaccent', upper(coalesce(e.cidade,''))) = any(
                  select unaccent('unaccent', upper(x)) from unnest(p_cidades) x)
             or exists (select 1 from gestores g
                         where g.empresa_id = e.id
                           and unaccent('unaccent', upper(coalesce(g.cidade,''))) = any(
                                 select unaccent('unaccent', upper(x)) from unnest(p_cidades) x)))
        and (p_estados is null or cardinality(p_estados) = 0
             or upper(coalesce(e.estado,'')) = any(select upper(x) from unnest(p_estados) x)
             or exists (select 1 from gestores g
                         where g.empresa_id = e.id
                           and upper(coalesce(g.estado,'')) = any(
                                 select upper(x) from unnest(p_estados) x)))
        -- perfil so existe no gestor: "empresas que tem gestor" e uma
        -- pergunta sobre as pessoas, nao sobre a empresa
        and (p_perfis is null or cardinality(p_perfis) = 0
             or exists (select 1 from gestores g
                         where g.empresa_id = e.id and g.perfil = any(p_perfis)))
    )
    select b.id, b.nome, b.cnpj, b.site, b.segmento, b.cidade, b.estado,
           b.qtd, count(*) over ()
    from base b
    where not p_so_com_gestores or b.qtd > 0
    order by b.nome
    limit p_limite offset p_offset;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_listar_equipe()
 RETURNS TABLE(id uuid, email text, nome text, role text, ativo boolean, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select a.id, a.email, a.nome, a.role, a.ativo, a.created_at
    from admins a
    order by a.role, a.email;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_listar_gestores(p_busca text DEFAULT NULL::text, p_perfis text[] DEFAULT NULL::text[], p_segmentos text[] DEFAULT NULL::text[], p_estados text[] DEFAULT NULL::text[], p_cidades text[] DEFAULT NULL::text[], p_posicoes text[] DEFAULT NULL::text[], p_com_email boolean DEFAULT NULL::boolean, p_limite integer DEFAULT 500, p_offset integer DEFAULT 0)
 RETURNS TABLE(id uuid, nome text, email text, empresa text, empresa_id uuid, cargo text, telefone text, cidade text, estado text, perfil text, linkedin text, segmento text, posicao_gestor text, total_geral bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select g.id, g.nome, g.email, g.empresa, g.empresa_id, g.cargo,
           g.telefone, g.cidade, g.estado, g.perfil, g.linkedin, g.segmento,
           g.posicao_gestor,
           count(*) over ()
    from gestores g
    where (p_busca is null or
           unaccent('unaccent', lower(g.nome || ' ' || coalesce(g.empresa,'')))
             like '%' || unaccent('unaccent', lower(p_busca)) || '%')
      -- array vazio conta como "sem filtro": o front manda [] quando o
      -- usuario desmarca tudo, e ali ele quer a base inteira, nao zero
      and (p_perfis is null or cardinality(p_perfis) = 0
           or g.perfil = any(p_perfis))
      and (p_segmentos is null or cardinality(p_segmentos) = 0
           or g.segmento = any(p_segmentos))
      and (p_estados is null or cardinality(p_estados) = 0
           or upper(coalesce(g.estado,'')) = any(
                select upper(x) from unnest(p_estados) x))
      -- cidade e digitada a mao na planilha e vem com e sem acento
      and (p_cidades is null or cardinality(p_cidades) = 0
           or unaccent('unaccent', upper(coalesce(g.cidade,''))) = any(
                select unaccent('unaccent', upper(x)) from unnest(p_cidades) x))
      and (p_posicoes is null or cardinality(p_posicoes) = 0
           or g.posicao_gestor = any(p_posicoes))
      and (p_com_email is null
           or (p_com_email and g.email is not null)
           or (not p_com_email and g.email is null))
    order by g.nome
    limit p_limite offset p_offset;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_listar_indicacoes(p_evento_slug text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(indicacao_id uuid, patrocinador text, nome text, empresa text, cargo text, email text, telefone text, observacao text, status text, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select i.id, p.empresa, i.nome, i.empresa, i.cargo, i.email,
           i.telefone, i.observacao, i.status, i.created_at
    from indicacoes i
    join patrocinadores p on p.id = i.patrocinador_id
    join eventos e on e.id = i.evento_id and e.slug = p_evento_slug
    where p_status is null or i.status = p_status
    order by i.created_at desc;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_listar_patrocinadores(p_evento_slug text)
 RETURNS TABLE(id uuid, empresa text, cnpj text, segmento text, site text, resumo text, o_que_vende text, natureza text, cidade text, estado text, cota text, ordem integer, quartos_extras integer, vagas_mesa_override integer, status text, fechado_em timestamp with time zone, enriquecido_em timestamp with time zone, usuarios bigint, reservas bigint, lounge text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select p.id, p.empresa, p.cnpj, p.segmento,
           p.site, p.resumo, p.o_que_vende, p.natureza,
           p.cidade, p.estado,
           c.nome, c.ordem_prioridade, p.quartos_extras_cota,
           p.vagas_mesa_override, p.status, p.fechado_em, p.enriquecido_em,
           (select count(*) from usuarios_patrocinador u
             where u.patrocinador_id = p.id and u.ativo),
           (select count(*) from reservas r
             where r.patrocinador_id = p.id and r.status <> 'cancelado'),
           p.lounge
    from patrocinadores p
    left join cotas c on c.id = p.cota_id
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade nulls last, p.empresa;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_listar_pendentes(p_evento_slug text)
 RETURNS TABLE(participante_id uuid, nome text, empresa text, cargo text, email text, telefone text, origem text, indicado_por text, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select pa.id, g.nome, g.empresa, g.cargo, g.email, g.telefone,
           pa.origem, pt.empresa, pa.created_at
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    join eventos  e on e.id = pa.evento_id and e.slug = p_evento_slug
    left join patrocinadores pt on pt.id = pa.indicado_por_patrocinador_id
    where pa.status = 'pendente'
    order by pa.created_at;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_listar_precos(p_evento_slug text)
 RETURNS TABLE(id uuid, item text, descricao text, valor numeric, idade_min integer, idade_max integer, faixa text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select pr.id, pr.item, pr.descricao, pr.valor,
           pr.idade_min, pr.idade_max,
           _rotulo_faixa(pr.idade_min, pr.idade_max)
    from precos pr
    join eventos e on e.id = pr.evento_id and e.slug = p_evento_slug
    order by pr.item, pr.idade_min nulls first;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_listar_rodadas()
 RETURNS TABLE(rodada_id text, evento text, patrocinador text, quando timestamp with time zone, empresas bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select coalesce(pr.sessao_id::text, 'sem-sessao-' || pr.evento_id::text),
           e.nome,
           coalesce(p.empresa, '—'),
           max(pr.created_at),
           count(distinct lower(trim(pr.empresa)))
    from prospeccoes pr
    join eventos e on e.id = pr.evento_id
    left join patrocinadores p on p.id = pr.patrocinador_id
    where pr.status in ('aprovado','convidado')
    group by 1, 2, 3
    order by 4 desc;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_listar_sugestoes(p_status text DEFAULT 'pendente'::text)
 RETURNS TABLE(id uuid, tipo text, gestor_nome text, empresa text, campo text, valor_atual text, valor_sugerido text, confianca numeric, fonte text, justificativa text, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select s.id, s.tipo, g.nome, coalesce(s.empresa, g.empresa), s.campo,
           s.valor_atual, s.valor_sugerido, s.confianca, s.fonte,
           s.justificativa, s.created_at
    from sugestoes_ia s
    left join gestores g on g.id = s.gestor_id
    where s.status = p_status
    order by s.confianca desc nulls last, s.created_at;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_listar_usuarios_patro(p_patrocinador_id uuid)
 RETURNS TABLE(id uuid, email text, nome text, telefone text, ativo boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select u.id, u.email, u.nome, u.telefone, u.ativo
    from usuarios_patrocinador u
    where u.patrocinador_id = p_patrocinador_id
    order by u.email;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_localidades_base()
 RETURNS TABLE(cidade text, estado text, empresas bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select coalesce(nullif(trim(g.cidade),''), '—'),
           coalesce(nullif(trim(g.estado),''), '—'),
           count(distinct lower(trim(g.empresa)))
    from gestores g
    where g.ativo and coalesce(trim(g.empresa),'') <> ''
    group by 1, 2
    order by 3 desc, 1;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_notificacao_teste()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v_email text; v_id uuid;
begin
  perform _exige_admin();

  v_email := auth.jwt() ->> 'email';
  if coalesce(trim(v_email),'') = '' then
    raise exception 'Sem e-mail no token' using errcode='22023';
  end if;

  insert into notificacoes (destinatario, tipo, assunto, corpo, status)
  values (v_email, 'teste',
          'Teste de envio — CIO Cerrado',
          'Se voce esta lendo isto, o envio de e-mail do sistema esta' || E'\n' ||
          'funcionando: chave do Resend valida, dominio aceito e' || E'\n' ||
          'remetente configurado.' || E'\n\n' ||
          'Disparado em ' || to_char(now(), 'DD/MM/YYYY HH24:MI') || '.',
          'enfileirada')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'destinatario', v_email);
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_notificacoes_com_erro(p_limite integer DEFAULT 20)
 RETURNS TABLE(id uuid, destinatario text, assunto text, tipo text, erro text, tentativas integer, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select n.id, n.destinatario, n.assunto, n.tipo, n.erro, n.tentativas, n.created_at
    from notificacoes n
    where n.status = 'erro'
    order by n.created_at desc
    limit greatest(coalesce(p_limite, 20), 1);
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_notificacoes_resumo()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v jsonb;
begin
  perform _exige_admin();
  select jsonb_build_object(
    'enfileiradas', count(*) filter (where status='enfileirada'),
    'enviadas',     count(*) filter (where status='enviada'),
    'com_erro',     count(*) filter (where status='erro')
  ) into v from notificacoes;
  return v;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_pesquisa_areas(p_evento_slug text)
 RETURNS TABLE(area text, aumentar bigint, estudo bigint, diminuir bigint, sem_previsao bigint, respondentes bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select
      inv.key,
      count(*) filter (where _intencao(inv.value #>> '{}') = 'aumentar'),
      count(*) filter (where _intencao(inv.value #>> '{}') = 'estudo'),
      count(*) filter (where _intencao(inv.value #>> '{}') = 'diminuir'),
      count(*) filter (where _intencao(inv.value #>> '{}') = 'sem_previsao'),
      count(*) filter (where _intencao(inv.value #>> '{}') is not null)
    from participante_perfil pp
    join participantes pa on pa.id = pp.participante_id
    join eventos e on e.id = pa.evento_id and e.slug = p_evento_slug
    cross join lateral jsonb_each(coalesce(pp.respostas -> 'investimentos','{}'::jsonb)) as inv
    where pa.status = 'aprovado'
    group by inv.key
    order by 2 desc, 1;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_pesquisa_por_area(p_evento_slug text, p_area text, p_intencao text DEFAULT 'aumentar'::text)
 RETURNS TABLE(nome text, empresa text, cargo text, email text, segmento text, faturamento text, resposta text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select g.nome, g.empresa, g.cargo, g.email, g.segmento,
           pp.faturamento,
           (pp.respostas -> 'investimentos' ->> p_area)
    from participante_perfil pp
    join participantes pa on pa.id = pp.participante_id
    join gestores g on g.id = pa.gestor_id
    join eventos e on e.id = pa.evento_id and e.slug = p_evento_slug
    where pa.status = 'aprovado'
      and _intencao(pp.respostas -> 'investimentos' ->> p_area) = p_intencao
    order by g.empresa, g.nome;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_pesquisa_resumo(p_evento_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v_total int; v_resp int; v_lgpd int;
begin
  perform _exige_admin();

  select count(*) into v_total
  from participantes pa
  join eventos e on e.id = pa.evento_id and e.slug = p_evento_slug
  where pa.status = 'aprovado';

  select count(*), count(*) filter (where pp.consentimento_lgpd)
    into v_resp, v_lgpd
  from participante_perfil pp
  join participantes pa on pa.id = pp.participante_id
  join eventos e on e.id = pa.evento_id and e.slug = p_evento_slug
  where pa.status = 'aprovado';

  return jsonb_build_object(
    'aprovados', v_total,
    'responderam', v_resp,
    'faltam', greatest(v_total - v_resp, 0),
    'consentiram_lgpd', v_lgpd);
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_prospeccao_base(p_evento_slug text, p_excluir_fornecedores boolean DEFAULT true, p_excluir_empresas text[] DEFAULT NULL::text[], p_excluir_convidados boolean DEFAULT true, p_tipo_sessao text DEFAULT 'jantar'::text, p_limite integer DEFAULT 500)
 RETURNS TABLE(empresa text, segmento text, faturamento text, funcionarios text, cidade text, estado text, cnpj text, exec1_id uuid, exec1_nome text, exec1_cargo text, exec1_email text, exec1_telefone text, exec2_id uuid, exec2_nome text, exec2_cargo text, exec2_email text, exec2_telefone text, contatos bigint, ja_convidado_em text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();

  return query
  with
  ja as (
    select lower(trim(g.empresa)) as empresa,
           string_agg(distinct ev.nome, ', ') as eventos
    from sessao_convidados sc
    join sessoes s   on s.id = sc.sessao_id and s.tipo = p_tipo_sessao
    join eventos ev  on ev.id = s.evento_id
    join participantes pa on pa.id = sc.participante_id
    join gestores g  on g.id = pa.gestor_id
    where sc.status = 'confirmado'
      and coalesce(trim(g.empresa),'') <> ''
    group by lower(trim(g.empresa))
  ),
  bloqueadas as (
    select lower(trim(x)) as empresa
    from unnest(coalesce(p_excluir_empresas, '{}'::text[])) as x
  ),
  ranqueado as (
    select g.*,
           row_number() over (
             partition by lower(trim(g.empresa))
             -- POSICAO GESTOR primeiro, cargo como desempate
             order by _rank_pos(g.posicao_gestor), _rank_cargo(g.cargo), g.nome) as pos,
           count(*) over (partition by lower(trim(g.empresa))) as n
    from gestores g
    where g.ativo
      and coalesce(trim(g.empresa),'') <> ''
      and coalesce(trim(g.nome),'') <> ''
      and (not p_excluir_fornecedores
           or coalesce(upper(unaccent('unaccent', g.perfil)),'')
              not like '%FORNECEDOR%')
  )
  select
    a.empresa, a.segmento, a.faturamento, a.funcionarios,
    a.cidade, a.estado, a.cnpj,
    a.id, a.nome, a.cargo, a.email, a.telefone,
    b.id, b.nome, b.cargo, b.email, b.telefone,
    a.n,
    j.eventos
  from ranqueado a
  left join ranqueado b
    on lower(trim(b.empresa)) = lower(trim(a.empresa)) and b.pos = 2
  left join ja j on j.empresa = lower(trim(a.empresa))
  left join bloqueadas bl on bl.empresa = lower(trim(a.empresa))
  where a.pos = 1
    and bl.empresa is null
    and (not p_excluir_convidados or j.empresa is null)
  order by a.empresa
  limit p_limite;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_remover_empresa(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  delete from empresas where id = p_id;
  return jsonb_build_object('ok', true);
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_resumo_quartos(p_evento_slug text)
 RETURNS TABLE(tipo text, total bigint, livres bigint, ocupados bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_admin();
  return query
    select q.tipo, count(*),
           count(*) filter (where not exists (
             select 1 from reservas r where r.quarto_id = q.id
               and r.status <> 'cancelado')),
           count(*) filter (where exists (
             select 1 from reservas r where r.quarto_id = q.id
               and r.status <> 'cancelado'))
    from quartos q
    join eventos e on e.id = q.evento_id and e.slug = p_evento_slug
    group by q.tipo
    order by q.tipo;
end;
$function$;


CREATE OR REPLACE FUNCTION gestao.admin_salvar_empresa(p_nome text, p_id uuid DEFAULT NULL::uuid, p_cnpj text DEFAULT NULL::text, p_site text DEFAULT NULL::text, p_segmento text DEFAULT NULL::text, p_cidade text DEFAULT NULL::text, p_estado text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v_id uuid; v_seg text;
begin
  perform _exige_admin();

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome da empresa' using errcode='22023';
  end if;

  v_seg := norm_segmento(p_segmento);
  if coalesce(trim(p_segmento),'') <> '' and v_seg is null then
    raise exception 'Segmento "%" nao esta na lista', p_segmento
      using errcode='22023';
  end if;

  if p_id is not null then
    update empresas set
      nome = trim(p_nome), cnpj = nullif(trim(p_cnpj),''),
      site = nullif(trim(p_site),''), segmento = v_seg,
      cidade = nullif(trim(p_cidade),''), estado = nullif(trim(p_estado),'')
    where id = p_id
    returning id into v_id;
    if v_id is null then
      raise exception 'Empresa nao encontrada' using errcode='P0002';
    end if;
  else
    insert into empresas (nome, cnpj, site, segmento, cidade, estado)
    values (trim(p_nome), nullif(trim(p_cnpj),''), nullif(trim(p_site),''),
            v_seg, nullif(trim(p_cidade),''), nullif(trim(p_estado),''))
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$function$;
