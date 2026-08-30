-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Integracao com o app do evento — Cenario A (arquivo melhorado)
--
-- Base: levantamento do Cowork no admin do app (30/08/2026) — ver
-- 03-analise-integracao-gestao-app.md e 04-especificacao-parceiro.md.
--
-- O app so sabe IMPORTAR PLANILHA hoje — nao tem API, nem endpoint de
-- consulta de empresa_id, nem upsert (reenviar um e-mail existente e
-- rejeitado, nao atualizado). Cenario B/C (API de verdade) dependem do
-- parceiro construir algo que nao existe ainda — isso virou o
-- documento de especificacao pra eles, nao codigo daqui.
--
-- O que DA pra fazer sem depender do parceiro: gerar a planilha certa,
-- no formato exato que o app aceita, incluindo a traducao nome da
-- empresa -> empresa_id numerico do app. Como o app nao expoe consulta
-- desse ID, a tabela de-para e alimentada A MAO: o admin importa
-- Empresas no app, olha os IDs que o app gerou, e preenche aqui.
--
-- Duas pontas de "empresa" do lado da gestao viram uma so linha do
-- lado do app, com evento_id obrigatorio:
--   - empresas (cadastro global dos CIOs) — so entra quem tem gestor
--     participando do evento em questao
--   - patrocinadores (ja e por evento) — entra com patrocinador=true
-- =====================================================================

set search_path = gestao, public;

alter table eventos add column if not exists id_app integer;
comment on column eventos.id_app is
  'ID numerico deste evento no admin do app (adm.ciocerrado.com.br) — olhado manualmente, o app nao expoe consulta. Sem isso preenchido, os exports de integracao nao tem evento_id pra mandar.';

create table if not exists mapa_empresa_app (
  id               uuid primary key default gen_random_uuid(),
  evento_id        uuid not null references eventos(id) on delete cascade,
  empresa_id       uuid references empresas(id) on delete cascade,
  patrocinador_id  uuid references patrocinadores(id) on delete cascade,
  empresa_id_app   integer not null,
  atualizado_em    timestamptz default now(),
  atualizado_por   text,
  check ((empresa_id is not null and patrocinador_id is null)
      or (empresa_id is null and patrocinador_id is not null)),
  unique (evento_id, empresa_id),
  unique (evento_id, patrocinador_id)
);

alter table mapa_empresa_app enable row level security;
create policy mapa_empresa_app_staff_all on mapa_empresa_app using (is_staff());

-- ---------------------------------------------------------------------
-- evento_id_app: 1 valor por evento, olhado no app e guardado aqui
-- ---------------------------------------------------------------------
create or replace function admin_definir_id_app_evento(p_evento_slug text, p_id_app integer)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  update eventos set id_app = p_id_app where slug = p_evento_slug;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- mapa de empresa -> empresa_id_app: leitura e escrita manual
-- ---------------------------------------------------------------------
create or replace function admin_listar_mapa_empresas_app(p_evento_slug text)
returns table(empresa_id uuid, patrocinador_id uuid, nome text, tipo text, empresa_id_app integer)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_evento uuid;
begin
  perform _exige_staff();
  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;

  return query
    select e.id, null::uuid, e.nome, 'cio'::text, m.empresa_id_app
    from empresas e
    join gestores g on g.empresa_id = e.id
    join participantes pa on pa.gestor_id = g.id
    left join mapa_empresa_app m on m.evento_id = v_evento and m.empresa_id = e.id
    where pa.evento_id = v_evento and pa.status = 'aprovado'
    group by e.id, e.nome, m.empresa_id_app

    union all

    select null::uuid, p.id, p.empresa, 'patrocinador'::text, m.empresa_id_app
    from patrocinadores p
    left join mapa_empresa_app m on m.evento_id = v_evento and m.patrocinador_id = p.id
    where p.evento_id = v_evento and p.status = 'ativo'

    order by 4 desc, 3;
end;
$$;

create or replace function admin_salvar_mapa_empresa_app(
  p_evento_slug text, p_empresa_id uuid, p_patrocinador_id uuid, p_empresa_id_app integer
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid;
begin
  perform _exige_staff();
  if (p_empresa_id is null) = (p_patrocinador_id is null) then
    raise exception 'Informe exatamente uma empresa OU um patrocinador' using errcode = '22023';
  end if;
  select id into v_evento from eventos where slug = p_evento_slug;

  -- NULL nao colide com NULL numa unique constraint comum — o
  -- ON CONFLICT abaixo so dispara pra linha que realmente bate na
  -- coluna preenchida, sem precisar de indice parcial
  if p_empresa_id is not null then
    insert into mapa_empresa_app (evento_id, empresa_id, patrocinador_id, empresa_id_app, atualizado_por)
    values (v_evento, p_empresa_id, null, p_empresa_id_app, auth.jwt() ->> 'email')
    on conflict (evento_id, empresa_id) do update
      set empresa_id_app = excluded.empresa_id_app, atualizado_em = now(), atualizado_por = excluded.atualizado_por;
  else
    insert into mapa_empresa_app (evento_id, empresa_id, patrocinador_id, empresa_id_app, atualizado_por)
    values (v_evento, null, p_patrocinador_id, p_empresa_id_app, auth.jwt() ->> 'email')
    on conflict (evento_id, patrocinador_id) do update
      set empresa_id_app = excluded.empresa_id_app, atualizado_em = now(), atualizado_por = excluded.atualizado_por;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- exports no formato do app
-- ---------------------------------------------------------------------
create or replace function admin_exportar_empresas_app(p_evento_slug text)
returns table(nome text, cnpj text, site text, segmento text, resumo text,
              nivel text, patrocinador boolean, evento_id integer,
              empresa_id uuid, patrocinador_id uuid, mapeado boolean)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_id_app integer;
begin
  perform _exige_staff();
  select id, id_app into v_evento, v_id_app from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;

  return query
    select distinct e.nome, e.cnpj, e.site, e.segmento, null::text,
           null::text, false, v_id_app,
           e.id, null::uuid, (m.empresa_id_app is not null)
    from empresas e
    join gestores g on g.empresa_id = e.id
    join participantes pa on pa.gestor_id = g.id
    left join mapa_empresa_app m on m.evento_id = v_evento and m.empresa_id = e.id
    where pa.evento_id = v_evento and pa.status = 'aprovado'

    union all

    select p.empresa, p.cnpj, p.site, p.segmento, p.resumo,
           c.nome, true, v_id_app,
           null::uuid, p.id, (m.empresa_id_app is not null)
    from patrocinadores p
    left join cotas c on c.id = p.cota_id
    left join mapa_empresa_app m on m.evento_id = v_evento and m.patrocinador_id = p.id
    where p.evento_id = v_evento and p.status = 'ativo';
end;
$$;

create or replace function admin_exportar_usuarios_app(p_evento_slug text)
returns table(name text, cargo text, email text, cidade text, estado text,
              linkedin text, segmento text, telefone text, empresa_id integer,
              ramo_atividade text, evento_id integer, mapeado boolean)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_id_app integer;
begin
  perform _exige_staff();
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
    join patrocinadores p on p.id = up.patrocinador_id
    left join mapa_empresa_app m on m.evento_id = v_evento and m.patrocinador_id = p.id
    where p.evento_id = v_evento and up.ativo and p.status = 'ativo';
end;
$$;

revoke all on function admin_definir_id_app_evento(text,integer) from public, anon;
revoke all on function admin_listar_mapa_empresas_app(text) from public, anon;
revoke all on function admin_salvar_mapa_empresa_app(text,uuid,uuid,integer) from public, anon;
revoke all on function admin_exportar_empresas_app(text) from public, anon;
revoke all on function admin_exportar_usuarios_app(text) from public, anon;
grant all on function admin_definir_id_app_evento(text,integer) to authenticated, service_role;
grant all on function admin_listar_mapa_empresas_app(text) to authenticated, service_role;
grant all on function admin_salvar_mapa_empresa_app(text,uuid,uuid,integer) to authenticated, service_role;
grant all on function admin_exportar_empresas_app(text) to authenticated, service_role;
grant all on function admin_exportar_usuarios_app(text) to authenticated, service_role;
