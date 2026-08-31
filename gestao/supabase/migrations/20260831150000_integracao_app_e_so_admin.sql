-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Integracao com o app do evento passa a exigir admin, nao so staff.
--
-- O ACHADO (relatorio de seguranca do Cowork, 31/08/2026)
--
-- A aba "App do evento" e admin-only na TELA (`ABAS_SO_ADMIN` no
-- admin.html esconde o botao do menu pra quem loga como staff). Mas as
-- quatro funcoes que essa aba chama checavam `_exige_staff()`, que
-- aceita QUALQUER linha ativa em `admins` — admin ou staff. Staff
-- digitando `#integracao-app` direto na URL nao via botao nenhum, mas a
-- pagina carregava e disparava as mesmas chamadas — e cada uma
-- devolvia dado de verdade: nome, e-mail e telefone de participante,
-- nome/site/segmento de empresa.
--
-- Esconder o botao do menu nunca foi controle de acesso — e so
-- deixar de mostrar. Quem decide se a chamada roda e o backend, e ele
-- estava checando o papel errado.
--
-- POR QUE SO ESSAS QUATRO
--
-- `admin_listar_eventos` tambem aparece no relatorio devolvendo dado
-- "de verdade" pra staff, mas isso e intencional e documentado na
-- propria tela de Equipe: staff enxerga evento de qualquer edicao, por
-- decisao ja fechada do projeto (README: "admins globais"). Toda tela
-- que staff PODE abrir — Quartos, Etiquetas, o seletor de evento no
-- topo — depende de `admin_listar_eventos` continuar staff. Restringir
-- essa quebraria a navegacao normal, nao so o vazamento.
-- =====================================================================

set search_path = gestao, public;

create or replace function admin_listar_mapa_empresas_app(p_evento_slug text)
returns table(empresa_id uuid, patrocinador_id uuid, nome text, tipo text, empresa_id_app integer)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_evento uuid;
begin
  perform _exige_admin();
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
  perform _exige_admin();
  if (p_empresa_id is null) = (p_patrocinador_id is null) then
    raise exception 'Informe exatamente uma empresa OU um patrocinador' using errcode = '22023';
  end if;
  select id into v_evento from eventos where slug = p_evento_slug;

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

create or replace function admin_exportar_empresas_app(p_evento_slug text)
returns table(nome text, cnpj text, site text, segmento text, resumo text,
              nivel text, patrocinador boolean, evento_id integer,
              empresa_id uuid, patrocinador_id uuid, mapeado boolean)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_id_app integer;
begin
  perform _exige_admin();
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
    join patrocinadores p on p.id = up.patrocinador_id
    left join mapa_empresa_app m on m.evento_id = v_evento and m.patrocinador_id = p.id
    where p.evento_id = v_evento and up.ativo and p.status = 'ativo';
end;
$$;

-- mapa_empresa_app tambem tinha policy de RLS aberta a qualquer staff
-- (`using (is_staff())`, sem with check, e sem cobrir DELETE de forma
-- explicita) — mas a tabela ja tem grant revogado de anon/authenticated
-- (armadilha #1 do projeto: ninguem le tabela direto, so RPC). A policy
-- so importa se algum dia um papel ganhar grant direto; ajustada aqui
-- pra acompanhar a mesma regra das funcoes, sem depender de lembrar disso.
drop policy if exists mapa_empresa_app_staff_all on mapa_empresa_app;
create policy mapa_empresa_app_admin_all on mapa_empresa_app
  for all to authenticated using (is_admin()) with check (is_admin());
