-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- migracao-02.sql  ·  cota unica, composicao de quartos e patrocinador
--
-- Rodar DEPOIS de funcoes-pesquisa.sql.
-- Seguro de rodar mais de uma vez.
--
-- Muda tres coisas:
--   1. evento pode ser de cota unica (caso do jantar avulso)
--   2. cota deixa de ter UM tipo de quarto e passa a ter composicao
--      (ex.: 2 duplos + 2 singles)
--   3. patrocinador ganha site, resumo e natureza, para o cadastro
--      poder ser enriquecido
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 1. EVENTO DE COTA UNICA
-- =====================================================================

-- Num evento de cota unica nao existe fila de escolha: todo mundo tem
-- o mesmo direito. E o caso do jantar avulso, que nao precisa de
-- Esmeralda/Diamante/Platina.
alter table eventos add column if not exists cota_unica boolean not null default false;

-- =====================================================================
-- 2. COMPOSICAO DE QUARTOS POR COTA
--
-- quartos_incluidos + tipo_quarto_padrao davam conta de "4 duplos",
-- mas nao de "2 duplos e 2 singles". As colunas antigas continuam na
-- tabela para nao quebrar nada, mas a fonte de verdade passa a ser
-- cota_quartos.
-- =====================================================================

create table if not exists cota_quartos (
  id         uuid primary key default gen_random_uuid(),
  cota_id    uuid not null references cotas(id) on delete cascade,
  tipo       text not null check (tipo in ('single','duplo','triplo')),
  quantidade int  not null default 0 check (quantidade >= 0),
  created_at timestamptz default now()
);
create unique index if not exists cota_quartos_uk on cota_quartos(cota_id, tipo);

alter table cota_quartos enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                 where schemaname='gestao' and tablename='cota_quartos') then
    create policy cota_quartos_staff_all on cota_quartos
      for all using (is_staff()) with check (is_staff());
  end if;
end $$;

-- Migra o que ja existe: cada cota vira uma linha com o tipo padrao.
insert into cota_quartos (cota_id, tipo, quantidade)
select c.id, c.tipo_quarto_padrao, c.quartos_incluidos
from cotas c
where c.quartos_incluidos > 0
on conflict (cota_id, tipo) do nothing;

-- =====================================================================
-- 3. PATROCINADOR: CAMPOS DE ENRIQUECIMENTO
-- =====================================================================

alter table patrocinadores add column if not exists site text;
alter table patrocinadores add column if not exists resumo text;
alter table patrocinadores add column if not exists cidade text;
alter table patrocinadores add column if not exists estado text;
alter table patrocinadores add column if not exists natureza text
  check (natureza is null or natureza in ('privada','hibrida','publica'));
alter table patrocinadores add column if not exists enriquecido_em timestamptz;

-- =====================================================================
-- 4. FUNCOES ATUALIZADAS
--
-- Toda funcao cujo formato de retorno muda precisa de DROP antes do
-- CREATE OR REPLACE: o Postgres nao troca colunas de saida so com
-- REPLACE quando o numero ou tipo delas muda (erro 42P13).
-- =====================================================================

-- ---------- cotas ----------

drop function if exists admin_listar_cotas(text);

create or replace function admin_listar_cotas(p_evento_slug text)
returns table (id uuid, nome text, ordem_prioridade int,
               quartos jsonb, total_quartos bigint,
               vagas_mesa_redonda int, tem_reuniao_exclusiva boolean,
               tem_jantar boolean, patrocinadores bigint,
               lista_patrocinadores jsonb)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
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
                     where p.cota_id = c.id and p.status = 'ativo'), '[]'::jsonb)
    from cotas c
    join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade;
end;
$$;

-- p_quartos vem como {"duplo":2,"single":2}
create or replace function admin_salvar_cota(
  p_evento_slug text,
  p_nome text,
  p_ordem int,
  p_quartos jsonb default '{}'::jsonb,
  p_vagas_mesa int default 0,
  p_reuniao boolean default false,
  p_jantar boolean default false
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_unica boolean; v_conflito text;
  v_cota uuid; v_par record; v_ordem int; v_total int := 0;
begin
  perform _exige_admin();

  select id, cota_unica into v_evento, v_unica
  from eventos where slug = p_evento_slug;

  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome da cota' using errcode='22023';
  end if;

  -- Em evento de cota unica nao ha fila, entao a ordem nao e pedida na
  -- tela; forcamos 1 para nao deixar nulo e quebrar a view de ordem.
  v_ordem := case when v_unica then 1 else p_ordem end;

  if v_ordem is null or v_ordem < 1 then
    raise exception 'A ordem de prioridade comeca em 1' using errcode='22023';
  end if;

  if not v_unica then
    select c.nome into v_conflito from cotas c
     where c.evento_id = v_evento and c.ordem_prioridade = v_ordem
       and lower(c.nome) <> lower(trim(p_nome));
    if v_conflito is not null then
      raise exception 'A posicao % ja e da cota "%"', v_ordem, v_conflito
        using errcode='23505';
    end if;
  end if;

  insert into cotas (evento_id, nome, ordem_prioridade, vagas_mesa_redonda,
                     tem_reuniao_exclusiva, tem_jantar,
                     quartos_incluidos, tipo_quarto_padrao)
  values (v_evento, trim(p_nome), v_ordem, coalesce(p_vagas_mesa,0),
          p_reuniao, p_jantar, 0, 'duplo')
  on conflict (evento_id, nome) do update set
    ordem_prioridade = excluded.ordem_prioridade,
    vagas_mesa_redonda = excluded.vagas_mesa_redonda,
    tem_reuniao_exclusiva = excluded.tem_reuniao_exclusiva,
    tem_jantar = excluded.tem_jantar
  returning id into v_cota;

  -- composicao substitui a anterior inteira: a tela edita o conjunto
  delete from cota_quartos where cota_id = v_cota;

  for v_par in
    select key as tipo, (value #>> '{}')::int as qtd
    from jsonb_each(coalesce(p_quartos, '{}'::jsonb))
  loop
    if v_par.tipo not in ('single','duplo','triplo') then
      raise exception 'Tipo de quarto invalido: %', v_par.tipo using errcode='22023';
    end if;
    if coalesce(v_par.qtd,0) > 0 then
      insert into cota_quartos (cota_id, tipo, quantidade)
      values (v_cota, v_par.tipo, v_par.qtd);
      v_total := v_total + v_par.qtd;
    end if;
  end loop;

  -- mantem as colunas antigas coerentes para quem ainda as le
  update cotas set quartos_incluidos = v_total where id = v_cota;

  return jsonb_build_object('ok', true, 'id', v_cota, 'total_quartos', v_total);
end;
$$;

-- Define de uma vez quais patrocinadores pertencem a uma cota.
-- Quem sai fica sem cota, nao e apagado.
create or replace function admin_definir_patrocinadores_cota(
  p_cota_id uuid,
  p_patrocinadores uuid[]
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_dentro int; v_fora int;
begin
  perform _exige_admin();

  select evento_id into v_evento from cotas where id = p_cota_id;
  if v_evento is null then
    raise exception 'Cota nao encontrada' using errcode='P0002';
  end if;

  -- tira da cota quem nao esta mais na lista
  update patrocinadores set cota_id = null
   where cota_id = p_cota_id
     and not (id = any(coalesce(p_patrocinadores, '{}'::uuid[])));
  get diagnostics v_fora = row_count;

  -- so aceita patrocinador do mesmo evento
  update patrocinadores set cota_id = p_cota_id
   where id = any(coalesce(p_patrocinadores, '{}'::uuid[]))
     and evento_id = v_evento;
  get diagnostics v_dentro = row_count;

  return jsonb_build_object('ok', true, 'na_cota', v_dentro, 'removidos', v_fora);
end;
$$;

-- ---------- geracao de quartos com composicao ----------

create or replace function admin_gerar_quartos_cota(p_patrocinador_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_cota uuid; v_extras int;
  v_comp record; v_existentes int; v_criar int; v_i int;
  v_seq int; v_total int := 0;
begin
  perform _exige_admin();

  select p.evento_id, p.cota_id, p.quartos_extras_cota
    into v_evento, v_cota, v_extras
  from patrocinadores p where p.id = p_patrocinador_id;

  if v_cota is null then
    raise exception 'Patrocinador sem cota definida' using errcode='P0002';
  end if;

  -- numeracao continua de onde parou, contando inclusive quartos extras
  select count(*) into v_seq from reservas
   where patrocinador_id = p_patrocinador_id and status <> 'cancelado';

  -- uma linha por tipo: a cota pode ter 2 duplos e 2 singles
  for v_comp in
    select tipo, quantidade from cota_quartos
    where cota_id = v_cota and quantidade > 0
    order by tipo
  loop
    select count(*) into v_existentes from reservas
     where patrocinador_id = p_patrocinador_id
       and origem = 'cota' and tipo = v_comp.tipo and status <> 'cancelado';

    v_criar := greatest(v_comp.quantidade - v_existentes, 0);

    for v_i in 1 .. v_criar loop
      v_seq := v_seq + 1;
      insert into reservas (evento_id, patrocinador_id, rotulo, tipo,
                            origem, status)
      values (v_evento, p_patrocinador_id, 'Quarto ' || v_seq,
              v_comp.tipo, 'cota', 'rascunho');
      v_total := v_total + 1;
    end loop;
  end loop;

  -- quartos extras negociados fora da cota usam o tipo mais comum dela
  if coalesce(v_extras,0) > 0 then
    select count(*) into v_existentes from reservas
     where patrocinador_id = p_patrocinador_id
       and origem = 'cota' and status <> 'cancelado';

    if v_existentes < (select coalesce(sum(quantidade),0) from cota_quartos
                       where cota_id = v_cota) + v_extras then
      for v_i in 1 .. v_extras loop
        v_seq := v_seq + 1;
        insert into reservas (evento_id, patrocinador_id, rotulo, tipo,
                              origem, status)
        values (v_evento, p_patrocinador_id, 'Quarto ' || v_seq,
                coalesce((select tipo from cota_quartos where cota_id = v_cota
                          order by quantidade desc limit 1), 'duplo'),
                'cota', 'rascunho');
        v_total := v_total + 1;
      end loop;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'criados', v_total);
end;
$$;

-- ---------- patrocinadores ----------

drop function if exists admin_listar_patrocinadores(text);

create or replace function admin_listar_patrocinadores(p_evento_slug text)
returns table (id uuid, empresa text, cnpj text, segmento text,
               site text, resumo text, o_que_vende text, natureza text,
               cidade text, estado text,
               cota text, ordem int, quartos_extras int,
               vagas_mesa_override int, status text,
               fechado_em timestamptz, enriquecido_em timestamptz,
               usuarios bigint, reservas bigint)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select p.id, p.empresa, p.cnpj, p.segmento,
           p.site, p.resumo, p.o_que_vende, p.natureza,
           p.cidade, p.estado,
           c.nome, c.ordem_prioridade, p.quartos_extras_cota,
           p.vagas_mesa_override, p.status, p.fechado_em, p.enriquecido_em,
           (select count(*) from usuarios_patrocinador u
             where u.patrocinador_id = p.id and u.ativo),
           (select count(*) from reservas r
             where r.patrocinador_id = p.id and r.status <> 'cancelado')
    from patrocinadores p
    left join cotas c on c.id = p.cota_id
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade nulls last, p.empresa;
end;
$$;

create or replace function admin_salvar_patrocinador(
  p_evento_slug text,
  p_empresa text,
  p_cota_nome text default null,
  p_cnpj text default null,
  p_segmento text default null,
  p_o_que_vende text default null,
  p_quartos_extras int default 0,
  p_vagas_mesa_override int default null,
  p_status text default 'ativo',
  p_site text default null,
  p_resumo text default null,
  p_natureza text default null,
  p_cidade text default null,
  p_estado text default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_cota uuid; v_id uuid;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if coalesce(trim(p_empresa),'') = '' then
    raise exception 'Informe o nome da empresa' using errcode='22023';
  end if;

  if p_cota_nome is not null and trim(p_cota_nome) <> '' then
    select id into v_cota from cotas
     where evento_id = v_evento and lower(nome) = lower(trim(p_cota_nome));
    if v_cota is null then
      raise exception 'Cota "%" nao existe neste evento', p_cota_nome
        using errcode='P0002';
    end if;
  end if;

  insert into patrocinadores (evento_id, cota_id, empresa, cnpj, segmento,
                              o_que_vende, quartos_extras_cota,
                              vagas_mesa_override, status,
                              site, resumo, natureza, cidade, estado)
  values (v_evento, v_cota, trim(p_empresa), p_cnpj, p_segmento,
          p_o_que_vende, coalesce(p_quartos_extras,0),
          p_vagas_mesa_override, p_status,
          p_site, p_resumo, p_natureza, p_cidade, p_estado)
  on conflict (evento_id, lower(empresa)) do update set
    cota_id = coalesce(excluded.cota_id, patrocinadores.cota_id),
    cnpj = coalesce(excluded.cnpj, patrocinadores.cnpj),
    segmento = coalesce(excluded.segmento, patrocinadores.segmento),
    o_que_vende = coalesce(excluded.o_que_vende, patrocinadores.o_que_vende),
    quartos_extras_cota = excluded.quartos_extras_cota,
    vagas_mesa_override = excluded.vagas_mesa_override,
    status = excluded.status,
    site = coalesce(excluded.site, patrocinadores.site),
    resumo = coalesce(excluded.resumo, patrocinadores.resumo),
    natureza = coalesce(excluded.natureza, patrocinadores.natureza),
    cidade = coalesce(excluded.cidade, patrocinadores.cidade),
    estado = coalesce(excluded.estado, patrocinadores.estado)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- Grava o resultado do enriquecimento. Separado do save normal para o
-- carimbo enriquecido_em so mudar quando a analise de fato rodou.
create or replace function admin_enriquecer_patrocinador(
  p_id uuid,
  p_site text default null,
  p_resumo text default null,
  p_o_que_vende text default null,
  p_segmento text default null,
  p_natureza text default null,
  p_cidade text default null,
  p_estado text default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();

  update patrocinadores set
    site        = coalesce(nullif(trim(p_site),''), site),
    resumo      = coalesce(nullif(trim(p_resumo),''), resumo),
    o_que_vende = coalesce(nullif(trim(p_o_que_vende),''), o_que_vende),
    segmento    = coalesce(nullif(trim(p_segmento),''), segmento),
    natureza    = coalesce(nullif(trim(p_natureza),''), natureza),
    cidade      = coalesce(nullif(trim(p_cidade),''), cidade),
    estado      = coalesce(nullif(trim(p_estado),''), estado),
    enriquecido_em = now()
  where id = p_id;

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- evento com cota unica ----------

drop function if exists admin_listar_eventos();

create or replace function admin_listar_eventos()
returns table (id uuid, slug text, nome text, local text,
               data_inicio date, data_fim date, status text,
               cota_unica boolean,
               prazo_contrato date, prazo_rooming date,
               prazo_cancelamento date, participantes bigint)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select e.id, e.slug, e.nome, e.local, e.data_inicio, e.data_fim,
           e.status, e.cota_unica,
           e.prazo_contrato, e.prazo_rooming, e.prazo_cancelamento,
           (select count(*) from participantes p where p.evento_id = e.id)
    from eventos e
    order by e.data_inicio desc nulls last;
end;
$$;

create or replace function admin_salvar_evento(
  p_slug text,
  p_nome text,
  p_local text default null,
  p_data_inicio date default null,
  p_data_fim date default null,
  p_status text default 'rascunho',
  p_prazo_contrato date default null,
  p_prazo_rooming date default null,
  p_prazo_cancelamento date default null,
  p_sympla_event_id text default null,
  p_cota_unica boolean default false
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_slug text; v_id uuid; v_cotas int;
begin
  perform _exige_admin();

  v_slug := trim(both '-' from regexp_replace(
    lower(unaccent('unaccent', coalesce(trim(p_slug),''))), '[^a-z0-9]+','-','g'));

  if v_slug = '' then
    raise exception 'Informe o identificador do evento' using errcode='22023';
  end if;
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome do evento' using errcode='22023';
  end if;
  if p_status not in ('rascunho','aberto','encerrado') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;
  if p_data_inicio is not null and p_data_fim is not null
     and p_data_fim < p_data_inicio then
    raise exception 'A data final e anterior a inicial' using errcode='22023';
  end if;

  -- Virar cota unica com varias cotas ja criadas deixaria a fila de
  -- escolha sem sentido, entao o caminho e limpar as cotas antes.
  if p_cota_unica then
    select count(*) into v_cotas from cotas c
    join eventos e on e.id = c.evento_id
    where e.slug = v_slug;
    if v_cotas > 1 then
      raise exception
        'Este evento tem % cotas. Remova-as antes de marcar como cota unica.', v_cotas
        using errcode='22023';
    end if;
  end if;

  insert into eventos (slug, nome, local, data_inicio, data_fim, status,
                       prazo_contrato, prazo_rooming, prazo_cancelamento,
                       sympla_event_id, cota_unica)
  values (v_slug, trim(p_nome), p_local, p_data_inicio, p_data_fim, p_status,
          p_prazo_contrato, p_prazo_rooming, p_prazo_cancelamento,
          p_sympla_event_id, coalesce(p_cota_unica,false))
  on conflict (slug) do update set
    nome = excluded.nome, local = excluded.local,
    data_inicio = excluded.data_inicio, data_fim = excluded.data_fim,
    status = excluded.status,
    prazo_contrato = excluded.prazo_contrato,
    prazo_rooming = excluded.prazo_rooming,
    prazo_cancelamento = excluded.prazo_cancelamento,
    sympla_event_id = coalesce(excluded.sympla_event_id, eventos.sympla_event_id),
    cota_unica = excluded.cota_unica
  returning id into v_id;

  -- Evento de cota unica ja nasce com a cota pronta: sem ela o
  -- patrocinador nao consegue ser cadastrado.
  if coalesce(p_cota_unica,false) then
    insert into cotas (evento_id, nome, ordem_prioridade, quartos_incluidos,
                       tipo_quarto_padrao, vagas_mesa_redonda,
                       tem_reuniao_exclusiva, tem_jantar)
    values (v_id, 'Única', 1, 0, 'duplo', 0, false, true)
    on conflict (evento_id, nome) do nothing;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'slug', v_slug,
                            'cota_unica', coalesce(p_cota_unica,false));
end;
$$;

grant execute on function
  admin_listar_cotas(text),
  admin_salvar_cota(text, text, int, jsonb, int, boolean, boolean),
  admin_definir_patrocinadores_cota(uuid, uuid[]),
  admin_gerar_quartos_cota(uuid),
  admin_listar_patrocinadores(text),
  admin_salvar_patrocinador(text, text, text, text, text, text, int, int, text, text, text, text, text, text),
  admin_enriquecer_patrocinador(uuid, text, text, text, text, text, text, text),
  admin_listar_eventos(),
  admin_salvar_evento(text, text, text, date, date, text, date, date, date, text, boolean)
to authenticated;

-- As assinaturas antigas ficaram orfas depois da mudanca de parametros.
-- Sem isto o PostgREST fica com duas versoes e nao sabe qual chamar.
drop function if exists admin_salvar_cota(text, text, int, int, text, int, boolean, boolean);
drop function if exists admin_salvar_patrocinador(text, text, text, text, text, text, int, int, text);
drop function if exists admin_salvar_evento(text, text, text, date, date, text, date, date, date, text);
