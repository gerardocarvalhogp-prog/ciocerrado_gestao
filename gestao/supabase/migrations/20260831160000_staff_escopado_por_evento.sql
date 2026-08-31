-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Staff so ve o evento que esta associado. Admin continua vendo todos.
--
-- O QUE MUDA
--
-- `admins` continua global — role e o mesmo em qualquer edicao, decisao
-- ja fechada do projeto (README: "admins globais"). O que era global
-- ATE AGORA era tambem o CONTEUDO: staff sem associacao nenhuma
-- enxergava todo evento, so por ter uma linha ativa em `admins`. E foi
-- exatamente isso que o relatorio de seguranca do Cowork (31/08)
-- registrou como achado informativo — staff trocando `?evento=` via
-- URL e vendo dado de um evento que nao era o dele.
--
-- Agora `admin_eventos` guarda QUAIS eventos cada staff acompanha.
-- Admin ignora essa tabela por completo (bypass em `is_admin()`, como
-- em todo o resto do schema) — a mudanca e so pro papel staff.
--
-- BACKFILL: NAO QUEBRA QUEM JA TEM ACESSO HOJE
--
-- Sem backfill, toda staff ativa perderia acesso a todo evento no
-- instante em que esta migration roda — ninguem pediu isso, e travaria
-- gente no meio do trabalho. Associa cada staff ativa a cada evento que
-- ja existe agora. Dali em diante, quem decide se afrouxa isso e o
-- admin, na aba Equipe — a migration so garante que o dia do deploy nao
-- muda nada pra ninguem.
--
-- ALCANCE DESTA LEVA: SO QUEM RECEBE p_evento_slug DIRETO
--
-- 22 funcoes staff (Etiquetas, Quartos, Checkin, Relatorios, Pendencias,
-- Financeiro-listagem, Brindes, Atividades, Sessoes, Prospeccao) trocam
-- o guard aqui. Ficam de fora, por ora, as que operam por id de sessao/
-- jantar/brinde/checkin/atividade/convidado sem receber o slug — essas
-- ainda enxergam qualquer evento se alguem souber o id. E uma leva
-- maior, que fica para uma proxima migration; registrado no relatorio
-- de seguranca para nao ser esquecido.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. A ASSOCIACAO, E O BACKFILL QUE PRESERVA O ACESSO DE HOJE
-- ---------------------------------------------------------------------
create table if not exists admin_eventos (
  admin_id   uuid not null references admins(id) on delete cascade,
  evento_id  uuid not null references eventos(id) on delete cascade,
  created_at timestamptz default now(),
  primary key (admin_id, evento_id)
);

alter table admin_eventos enable row level security;
create policy admin_eventos_admin_all on admin_eventos
  for all to authenticated using (is_admin()) with check (is_admin());
revoke all on table admin_eventos from anon, authenticated;

insert into admin_eventos (admin_id, evento_id)
select a.id, e.id
from admins a
cross join eventos e
where a.ativo
on conflict (admin_id, evento_id) do nothing;

-- ---------------------------------------------------------------------
-- 2. O GUARD: ADMIN PASSA DIRETO, STAFF PRECISA DE ASSOCIACAO
-- ---------------------------------------------------------------------
create or replace function _exige_staff_do_evento_slug(p_evento_slug text)
returns void language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid;
begin
  perform _exige_staff();
  if is_admin() then return; end if;

  select id into v_evento from eventos where slug = p_evento_slug;
  -- evento inexistente: deixa o corpo da funcao chamadora acusar isso
  -- do jeito que ja acusa hoje (ou simplesmente nao acha nada) — aqui
  -- so decide sobre acesso, nao sobre existencia
  if v_evento is null then return; end if;

  if not exists (
    select 1 from admins a
    join admin_eventos ae on ae.admin_id = a.id
    where a.email_norm = norm_doc(auth.jwt() ->> 'email')
      and a.ativo and ae.evento_id = v_evento
  ) then
    raise exception 'Sua conta nao esta associada a este evento' using errcode = '42501';
  end if;
end;
$$;

revoke execute on function _exige_staff_do_evento_slug(text) from public, anon;
grant execute on function _exige_staff_do_evento_slug(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. AS 22 FUNCOES: MESMO CORPO, SO O GUARD TROCA
-- ---------------------------------------------------------------------

create or replace function gestao.admin_brindes_resumo(p_evento_slug text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
declare v_out jsonb;
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);

  select jsonb_build_object(
    'total',      count(*),
    'prometido',  count(*) filter (where b.status = 'prometido'),
    'enviado',    count(*) filter (where b.status = 'enviado'),
    'recebido',   count(*) filter (where b.status = 'recebido'),
    'entregue',   count(*) filter (where b.status = 'entregue'),
    'cancelado',  count(*) filter (where b.status = 'cancelado'),
    'no_stand',   count(*) filter (where b.destino = 'stand'),
    'no_quarto',  count(*) filter (where b.destino = 'quarto'),
    'empresas',   count(distinct b.patrocinador_id))
  into v_out
  from brindes b
  join patrocinadores p on p.id = b.patrocinador_id
  join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
  where b.vai_enviar;

  return coalesce(v_out, jsonb_build_object('total', 0));
end;
$function$;

create or replace function gestao.admin_etiquetas(p_evento_slug text, p_categoria text DEFAULT NULL::text, p_origem text DEFAULT NULL::text)
 returns table(pessoa_key text, apto text, nome text, empresa text, categoria text, origem text)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select v.pessoa_key, v.apto, v.nome, v.empresa, v.categoria, v.origem
    from v_etiquetas v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    where (p_categoria is null or v.categoria = p_categoria)
      and (p_origem is null or v.origem = p_origem)
    order by
      (v.apto is null),
      nullif(regexp_replace(coalesce(v.apto,''),'[^0-9]','','g'),'')::int nulls last,
      v.categoria, v.nome;
end;
$function$;

create or replace function gestao.admin_etiquetas_resumo(p_evento_slug text)
 returns table(origem text, categoria text, total bigint)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select v.origem, v.categoria, count(*)
    from v_etiquetas v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    group by v.origem, v.categoria
    order by v.origem, v.categoria;
end;
$function$;

create or replace function gestao.admin_listar_alocacao(p_evento_slug text, p_apenas_sem_quarto boolean DEFAULT false)
 returns table(ocupante_id uuid, reserva_id uuid, nome text, empresa text, tipo text, quarto_id uuid, quarto_numero text, quarto_tipo text)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select o.id, r.id, o.nome,
           coalesce(p.empresa, g.empresa, r.rotulo),
           o.tipo, q.id, q.numero, r.tipo
    from ocupantes o
    join reservas r on r.id = o.reserva_id and r.status <> 'cancelado'
    join eventos  e on e.id = r.evento_id and e.slug = p_evento_slug
    left join quartos q on q.id = r.quarto_id
    left join patrocinadores p on p.id = r.patrocinador_id
    left join participantes pa on pa.id = r.participante_id
    left join gestores g on g.id = pa.gestor_id
    where (not p_apenas_sem_quarto or r.quarto_id is null)
    order by coalesce(p.empresa, g.empresa, r.rotulo), o.nome;
end;
$function$;

create or replace function gestao.admin_listar_atividades(p_evento_slug text)
 returns table(id uuid, nome text, data date, horario_inicio time without time zone, horario_fim time without time zone, local text, esperados bigint, presentes bigint)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select a.id, a.nome, a.data, a.horario_inicio, a.horario_fim, a.local,
           (select count(*) from v_esperados v where v.evento_id = a.evento_id),
           (select count(*) from checkins c where c.atividade_id = a.id and c.desfeito_em is null)
    from atividades a
    join eventos e on e.id = a.evento_id and e.slug = p_evento_slug
    order by a.data nulls last, a.horario_inicio nulls last, a.nome;
end;
$function$;

create or replace function gestao.admin_listar_brindes(p_evento_slug text, p_status text DEFAULT NULL::text, p_limite integer DEFAULT 500, p_offset integer DEFAULT 0)
 returns table(brinde_id uuid, empresa text, cota text, destino text, quartos integer, descricao text, quantidade integer, status text, transportadora text, rastreio text, enviado_em timestamp with time zone, recebido_em timestamp with time zone, recebido_por text, entregue_em timestamp with time zone, entregue_por text, observacao text)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);

  return query
    select b.id, p.empresa, c.nome, b.destino,
           (select count(*)::int from reservas r
             where r.patrocinador_id = p.id and r.status <> 'cancelado'),
           b.descricao, b.quantidade, b.status,
           b.transportadora, b.rastreio,
           b.enviado_em, b.recebido_em, b.recebido_por,
           b.entregue_em, b.entregue_por, b.observacao
    from brindes b
    join patrocinadores p on p.id = b.patrocinador_id
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    left join cotas c on c.id = p.cota_id
    where b.vai_enviar
      and (p_status is null or b.status = p_status)
    order by case b.status
               when 'prometido' then 1 when 'enviado' then 2
               when 'recebido'  then 3 when 'entregue' then 4
               else 5 end,
             case b.destino when 'quarto' then 1 else 2 end,
             p.empresa
    limit greatest(coalesce(p_limite, 500), 1)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$function$;

create or replace function gestao.admin_listar_faturas(p_evento_slug text, p_status text DEFAULT NULL::text, p_limite integer DEFAULT 500, p_offset integer DEFAULT 0)
 returns table(id uuid, tipo text, nome text, empresa text, email text, total numeric, status text, vencimento date, emitida_em timestamp with time zone, paga_em timestamp with time zone, forma_pagamento text, observacao text, itens text, total_geral bigint)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select f.id,
           case when f.participante_id is not null then 'participante'
                else 'patrocinador' end,
           coalesce(g.nome, p.empresa),
           coalesce(g.empresa, p.empresa),
           coalesce(g.email, (select u.email from usuarios_patrocinador u
                              where u.patrocinador_id = p.id and u.ativo
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
      and (p_status is null or f.status = p_status)
    order by (f.status = 'paga'), f.total desc
    limit p_limite offset p_offset;
end;
$function$;

create or replace function gestao.admin_listar_prospeccao(p_evento_slug text, p_sessao_id uuid DEFAULT NULL::uuid)
 returns table(id uuid, empresa text, nome text, cargo text, email text, telefone text, score numeric, natureza text, justificativa text, status text)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select pr.id, pr.empresa, g.nome, g.cargo, g.email, g.telefone,
           pr.score, pr.natureza, pr.justificativa, pr.status
    from prospeccoes pr
    left join gestores g on g.id = pr.gestor_id
    join eventos e on e.id = pr.evento_id and e.slug = p_evento_slug
    where (p_sessao_id is null or pr.sessao_id = p_sessao_id)
    order by pr.score desc nulls last, pr.empresa;
end;
$function$;

create or replace function gestao.admin_listar_quartos_equipe(p_evento_slug text)
 returns table(reserva_id uuid, rotulo text, tipo text, status text, quarto_id uuid, quarto_numero text, ocupantes jsonb)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select r.id, r.rotulo, r.tipo, r.status, q.id, q.numero,
      coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', o.id, 'nome', o.nome, 'cpf', o.cpf,
                 'telefone', o.telefone, 'email', o.email,
                 'usa_transfer', o.usa_transfer,
                 'transfer_origem', o.transfer_origem)
               order by o.created_at)
        from ocupantes o where o.reserva_id = r.id
      ), '[]'::jsonb) as ocupantes
    from reservas r
    join eventos e on e.id = r.evento_id and e.slug = p_evento_slug
    left join quartos q on q.id = r.quarto_id
    where r.origem = 'equipe' and r.status <> 'cancelado'
    order by r.rotulo;
end;
$function$;

create or replace function gestao.admin_listar_sessoes(p_evento_slug text, p_tipo text DEFAULT NULL::text)
 returns table(sessao_id uuid, patrocinador text, cota text, tipo text, data date, horario time without time zone, local text, vagas integer, escolhidos bigint, encerrada boolean)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select s.id, p.empresa, c.nome, s.tipo, s.data, s.horario, s.local,
           s.vagas,
           (select count(*) from sessao_convidados sc
             where sc.sessao_id = s.id and sc.status = 'confirmado'),
           (s.escolha_encerrada_em is not null or s.passou_em is not null)
    from sessoes s
    join patrocinadores p on p.id = s.patrocinador_id
    left join cotas c on c.id = p.cota_id
    join eventos e on e.id = s.evento_id and e.slug = p_evento_slug
    where p_tipo is null or s.tipo = p_tipo
    order by c.ordem_prioridade nulls last, p.empresa, s.data;
end;
$function$;

create or replace function gestao.admin_pendencias_lista(p_evento_slug text, p_etapa_chave text DEFAULT NULL::text, p_nivel text DEFAULT NULL::text, p_publico text DEFAULT NULL::text, p_limite integer DEFAULT 200, p_offset integer DEFAULT 0)
 returns table(sujeito_id uuid, sujeito_nome text, sujeito_empresa text, publico text, etapa_chave text, etapa_rotulo text, status text, aberta_em timestamp with time zone, concluida_em timestamp with time zone, dias_em_aberto integer, nivel text, destinatario_email text, total_geral bigint)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
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
$function$;

create or replace function gestao.admin_pendencias_resumo(p_evento_slug text)
 returns table(etapa_chave text, etapa_rotulo text, publico text, ok bigint, atencao bigint, atrasado bigint)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
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
$function$;

create or replace function gestao.admin_quartos_livres(p_evento_slug text)
 returns table(id uuid, numero text, tipo text, capacidade integer)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select q.id, q.numero, q.tipo, q.capacidade
    from quartos q
    join eventos e on e.id = q.evento_id and e.slug = p_evento_slug
    where q.status <> 'bloqueado'
      and not exists (select 1 from reservas r
                      where r.quarto_id = q.id and r.status <> 'cancelado')
    order by q.numero nulls last;
end;
$function$;

create or replace function gestao.admin_rel_checkins_detalhe(p_evento_slug text, p_empresa text DEFAULT NULL::text, p_limite integer DEFAULT 500, p_offset integer DEFAULT 0)
 returns table(empresa text, nome text, email text, registrado_em timestamp with time zone, total_geral bigint)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select p.empresa, c.nome, c.email, c.registrado_em, count(*) over ()
    from checkins c
    join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
    left join patrocinadores p on p.id = c.patrocinador_id
    where c.desfeito_em is null
      and (p_empresa is null or lower(p.empresa) = lower(p_empresa))
    order by p.empresa, c.registrado_em
    limit p_limite offset p_offset;
end;
$function$;

create or replace function gestao.admin_rel_checkins_resumo(p_evento_slug text)
 returns table(empresa text, total_checkins bigint)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select v.empresa, v.total_checkins
    from v_checkins_resumo v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    order by v.total_checkins desc, v.empresa;
end;
$function$;

create or replace function gestao.admin_rel_mailing(p_evento_slug text, p_limite integer DEFAULT 500, p_offset integer DEFAULT 0)
 returns table(perfil text, nome text, cargo text, empresa text, email text, telefone text, cnpj text, segmento text, estado text, total_geral bigint)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select g.perfil, g.nome, g.cargo, g.empresa, g.email, g.telefone,
           g.cnpj, g.segmento, g.estado, count(*) over ()
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    join eventos  e on e.id = pa.evento_id and e.slug = p_evento_slug
    where pa.status = 'aprovado'
    order by g.nome
    limit p_limite offset p_offset;
end;
$function$;

create or replace function gestao.admin_rel_painel(p_evento_slug text, p_limite integer DEFAULT 500, p_offset integer DEFAULT 0)
 returns table(participante_id uuid, nome text, empresa text, email text, status_inscricao text, status_contrato text, status_rooming text, usa_transfer boolean, quarto text, total_geral bigint)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select v.participante_id, v.nome, v.empresa, v.email,
           v.status_inscricao, v.status_contrato, v.status_rooming,
           v.usa_transfer, v.quarto,
           count(*) over ()
    from v_painel_participantes v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    order by v.empresa, v.nome
    limit p_limite offset p_offset;
end;
$function$;

create or replace function gestao.admin_rel_pesquisa(p_evento_slug text, p_limite integer DEFAULT 500, p_offset integer DEFAULT 0)
 returns table(nome text, empresa text, cargo text, email text, telefone text, segmento text, estado text, cnpj text, faturamento text, orcamento_ti text, colaboradores text, colaboradores_ti text, erp_atual text, dispositivos text, terceirizados text, consentimento_lgpd boolean, investimentos jsonb, perfil jsonb, respondeu boolean, total_geral bigint)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select g.nome, g.empresa, g.cargo, g.email, g.telefone,
           g.segmento, g.estado, g.cnpj,
           pp.faturamento, pp.orcamento_ti, pp.colaboradores,
           pp.colaboradores_ti, pp.erp_atual,
           pp.respostas ->> 'dispositivos',
           pp.respostas ->> 'terceirizados',
           pp.consentimento_lgpd,
           coalesce(pp.respostas -> 'investimentos', '{}'::jsonb),
           coalesce(pp.respostas -> 'perfil', '{}'::jsonb),
           (pp.participante_id is not null),
           count(*) over ()
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    join eventos  e on e.id = pa.evento_id and e.slug = p_evento_slug
    left join participante_perfil pp on pp.participante_id = pa.id
    where pa.status = 'aprovado'
    order by (pp.participante_id is null), g.empresa, g.nome
    limit p_limite offset p_offset;
end;
$function$;

create or replace function gestao.checkin_cadastrar(p_evento_slug text, p_nome text, p_empresa text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_telefone text DEFAULT NULL::text, p_cargo text DEFAULT NULL::text, p_categoria text DEFAULT 'PROTAGONISTA'::text, p_local text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare
  v_evento uuid; v_gestor uuid; v_part uuid;
  v_key text; v_reaproveitado boolean := false;
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome' using errcode='22023';
  end if;

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
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
            coalesce(nullif(trim(p_categoria),''), 'PROTAGONISTA'), 'manual')
    returning id into v_gestor;
  else
    update gestores set
      empresa  = coalesce(empresa, p_empresa),
      telefone = coalesce(telefone, p_telefone),
      cargo    = coalesce(cargo, p_cargo)
    where id = v_gestor;
  end if;

  select pa.id into v_part from participantes pa
   where pa.evento_id = v_evento and pa.gestor_id = v_gestor;

  if v_part is null then
    insert into participantes (evento_id, gestor_id, status, origem,
                               aprovado_em, aprovado_por)
    values (v_evento, v_gestor, 'aprovado', 'manual', now(),
            auth.jwt() ->> 'email')
    returning id into v_part;
  else
    update participantes set status = 'aprovado'
     where id = v_part and status <> 'aprovado';
  end if;

  v_key := 'participante:' || v_part::text;

  return checkin_registrar(p_evento_slug, v_key, p_local)
         || jsonb_build_object('cadastrado', true,
                               'gestor_reaproveitado', v_reaproveitado);
end;
$function$;

create or replace function gestao.checkin_listar(p_evento_slug text, p_termo text DEFAULT NULL::text, p_so_pendentes boolean DEFAULT false, p_limite integer DEFAULT 300)
 returns table(pessoa_key text, nome text, empresa text, categoria text, quarto text, checkin_id uuid, registrado_em timestamp with time zone)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
declare v_termo text;
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  v_termo := nullif(trim(coalesce(p_termo,'')), '');

  return query
    select v.pessoa_key, v.nome, v.empresa, v.categoria, v.quarto,
           c.id, c.registrado_em
    from v_esperados v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    left join checkins c on c.pessoa_key = v.pessoa_key
                        and c.evento_id = v.evento_id
                        and c.atividade_id is null
                        and c.desfeito_em is null
    where (v_termo is null
           or v.nome ilike '%'||v_termo||'%'
           or coalesce(v.empresa,'') ilike '%'||v_termo||'%'
           or coalesce(v.email,'') ilike '%'||v_termo||'%')
      and (not p_so_pendentes or c.id is null)
    order by (c.id is not null), v.nome
    limit p_limite;
end;
$function$;

create or replace function gestao.checkin_registrar(p_evento_slug text, p_pessoa_key text, p_local text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare
  v_evento uuid; v_nome text; v_email text; v_patro uuid;
  v_ocupante uuid; v_ja timestamptz; v_id uuid;
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);

  select v.evento_id, v.nome, v.email, v.patrocinador_id
    into v_evento, v_nome, v_email, v_patro
  from v_esperados v
  join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
  where v.pessoa_key = p_pessoa_key;

  if v_evento is null then
    raise exception 'Pessoa nao encontrada neste evento' using errcode='P0002';
  end if;

  if p_pessoa_key like 'ocupante:%' then
    v_ocupante := substring(p_pessoa_key from 10)::uuid;
  end if;

  select c.registrado_em into v_ja from checkins c
   where c.pessoa_key = p_pessoa_key and c.evento_id = v_evento
     and c.atividade_id is null
     and c.desfeito_em is null
   limit 1;

  if v_ja is not null then
    return jsonb_build_object('ok', true, 'ja_estava', true,
                              'nome', v_nome, 'registrado_em', v_ja);
  end if;

  insert into checkins (evento_id, patrocinador_id, ocupante_id, pessoa_key,
                        nome, email, local, registrado_por)
  values (v_evento, v_patro, v_ocupante, p_pessoa_key, v_nome, v_email,
          p_local, auth.jwt() ->> 'email')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'ja_estava', false,
                            'id', v_id, 'nome', v_nome);
end;
$function$;

create or replace function gestao.checkin_resumo(p_evento_slug text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
declare v_esperados int; v_feitos int;
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);

  select count(*) into v_esperados
  from v_esperados v
  join eventos e on e.id = v.evento_id and e.slug = p_evento_slug;

  select count(*) into v_feitos
  from checkins c
  join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
  where c.desfeito_em is null;

  return jsonb_build_object(
    'esperados', v_esperados,
    'feitos',    v_feitos,
    'pendentes', greatest(v_esperados - v_feitos, 0));
end;
$function$;

-- ---------------------------------------------------------------------
-- 4. O SELETOR DE EVENTO EM SI: admin ve tudo, staff so o associado
-- ---------------------------------------------------------------------
create or replace function gestao.admin_listar_eventos()
 returns table(id uuid, slug text, nome text, local text, data_inicio date, data_fim date, status text, cota_unica boolean, prazo_contrato date, prazo_rooming date, prazo_cancelamento date, participantes bigint, escolha_abre_em timestamp with time zone, sympla_url text, sympla_event_id text, usa_atividades boolean)
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
begin
  perform _exige_staff();
  return query
    select e.id, e.slug, e.nome, e.local, e.data_inicio, e.data_fim,
           e.status, e.cota_unica,
           e.prazo_contrato, e.prazo_rooming, e.prazo_cancelamento,
           (select count(*) from participantes p where p.evento_id = e.id),
           e.escolha_abre_em,
           e.sympla_url, e.sympla_event_id, e.usa_atividades
    from eventos e
    where is_admin() or exists (
      select 1 from admins a
      join admin_eventos ae on ae.admin_id = a.id
      where a.email_norm = norm_doc(auth.jwt() ->> 'email')
        and a.ativo and ae.evento_id = e.id
    )
    order by e.data_inicio desc nulls last;
end;
$function$;

-- ---------------------------------------------------------------------
-- 5. A TELA: QUAIS EVENTOS CADA MEMBRO DA EQUIPE ACOMPANHA
-- ---------------------------------------------------------------------
create or replace function admin_listar_eventos_membro(p_admin_id uuid)
returns table(evento_id uuid, evento_nome text, associado boolean)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  return query
    select e.id, e.nome, (ae.admin_id is not null)
    from eventos e
    left join admin_eventos ae on ae.evento_id = e.id and ae.admin_id = p_admin_id
    order by e.data_inicio desc nulls last;
end;
$$;

create or replace function admin_definir_eventos_membro(p_admin_id uuid, p_evento_ids uuid[])
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();

  if not exists (select 1 from admins where id = p_admin_id) then
    raise exception 'Membro nao encontrado' using errcode = 'P0002';
  end if;

  delete from admin_eventos where admin_id = p_admin_id;
  insert into admin_eventos (admin_id, evento_id)
  select p_admin_id, x from unnest(coalesce(p_evento_ids, array[]::uuid[])) as x;

  return jsonb_build_object('ok', true, 'eventos', coalesce(array_length(p_evento_ids,1),0));
end;
$$;

revoke execute on function admin_listar_eventos_membro(uuid) from public, anon;
revoke execute on function admin_definir_eventos_membro(uuid, uuid[]) from public, anon;
grant execute on function admin_listar_eventos_membro(uuid) to authenticated, service_role;
grant execute on function admin_definir_eventos_membro(uuid, uuid[]) to authenticated, service_role;
