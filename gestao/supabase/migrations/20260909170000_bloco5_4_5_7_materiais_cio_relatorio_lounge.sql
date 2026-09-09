-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Bloco 5.4 (parcial — catalogo/revistas por link externo) e 5.7
-- (relatorio do Lounge, no formato do mailing list ja existente).
--
-- 5.4 O catalogo de fornecedores e as revistas vêm de link externo
--     (confirmado pelo organizador) — o sistema so precisa guardar e
--     mostrar os links, nao hospedar arquivo. Materiais sao globais
--     (nao por evento): a mesma revista/catalogo vale pra toda edicao.
--
-- 5.7 O relatorio do Lounge segue o mesmo formato do mailing list que
--     admin_rel_mailing ja usa (uma linha por PESSOA de contato, com
--     nome/e-mail/telefone) — so que filtrado a quem tem numero de
--     lounge e com a coluna Lounge/Cota na frente. Reaproveita o
--     mesmo cartao "Carregar + tabela + Exportar Excel" da aba
--     Relatorios.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- ACHADO DURANTE A VALIDACAO, SEM RELACAO COM 5.4/5.7: overload orfao
-- de admin_salvar_cota com 9 parametros — a assinatura ORIGINAL da
-- baseline de 24/08, nunca dropada quando 20260901170000 acrescentou
-- limite_indicacoes/escolhe_convidados via CREATE OR REPLACE (que so
-- substitui funcao de MESMA assinatura; com assinatura diferente,
-- sempre cria uma segunda ao lado — o mesmo aviso que varias
-- migrations deste repositorio repetem, e que desta vez escapou).
-- Toda cadeia seguinte (20260902120000 em diante) dropou certinho a
-- versao anterior a cada mudanca, mas a de 9 parametros ficou pra
-- tras, viva, sem que ninguem tivesse motivo de olhar (chamada real
-- de admin.html manda todos os parametros por nome, entao nunca bateu
-- nela por acidente). So apareceu agora porque a validacao local
-- tentou uma chamada parcial. Efeito pratico se alguem chamar so com
-- os primeiros parametros (por nome ou posicional) num script/RPC
-- futuro: "function admin_salvar_cota(...) is not unique".
-- ---------------------------------------------------------------------
drop function if exists admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer);

-- ---------------------------------------------------------------------
-- 5.4 — materiais do CIO (catalogo de fornecedores, revistas)
-- ---------------------------------------------------------------------
create table if not exists materiais_cio (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('catalogo','revista')),
  titulo text not null,
  url text not null,
  ordem integer not null default 0,
  ativo boolean not null default true,
  created_at timestamptz not null default now()
);

alter table materiais_cio enable row level security;
create policy materiais_cio_staff_all on materiais_cio
  for all to authenticated using (is_staff()) with check (is_staff());
revoke all on table materiais_cio from anon, authenticated;

create or replace function admin_listar_materiais_cio(p_tipo text DEFAULT NULL::text)
returns table (id uuid, tipo text, titulo text, url text, ordem integer, ativo boolean)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select m.id, m.tipo, m.titulo, m.url, m.ordem, m.ativo
    from materiais_cio m
    where p_tipo is null or m.tipo = p_tipo
    order by m.tipo, m.ordem, m.titulo;
end;
$$;

revoke execute on function admin_listar_materiais_cio(text) from public, anon;
grant execute on function admin_listar_materiais_cio(text) to authenticated, service_role;

create or replace function admin_salvar_material_cio(
  p_id uuid DEFAULT NULL::uuid, p_tipo text DEFAULT NULL::text,
  p_titulo text DEFAULT NULL::text, p_url text DEFAULT NULL::text,
  p_ordem integer DEFAULT 0, p_ativo boolean DEFAULT true
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_id uuid;
begin
  perform _exige_admin();

  if p_tipo not in ('catalogo','revista') then
    raise exception 'Tipo invalido: %', p_tipo using errcode = '22023';
  end if;
  if coalesce(trim(p_titulo),'') = '' then
    raise exception 'Informe o titulo' using errcode = '22023';
  end if;
  if coalesce(trim(p_url),'') = '' then
    raise exception 'Informe a URL' using errcode = '22023';
  end if;

  if p_id is not null then
    update materiais_cio set
      tipo = p_tipo, titulo = trim(p_titulo), url = trim(p_url),
      ordem = coalesce(p_ordem,0), ativo = coalesce(p_ativo,true)
    where id = p_id
    returning id into v_id;
    if v_id is null then
      raise exception 'Material nao encontrado' using errcode = 'P0002';
    end if;
  else
    insert into materiais_cio (tipo, titulo, url, ordem, ativo)
    values (p_tipo, trim(p_titulo), trim(p_url), coalesce(p_ordem,0), coalesce(p_ativo,true))
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

revoke execute on function admin_salvar_material_cio(uuid,text,text,text,integer,boolean) from public, anon;
grant execute on function admin_salvar_material_cio(uuid,text,text,text,integer,boolean) to authenticated, service_role;

create or replace function admin_remover_material_cio(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  delete from materiais_cio where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function admin_remover_material_cio(uuid) from public, anon;
grant execute on function admin_remover_material_cio(uuid) to authenticated, service_role;

-- o CIO so ve o que esta ativo — precisa provar que e' participante de
-- ALGUM evento aberto (nao importa qual: material e' global)
create or replace function part_listar_materiais_cio(p_evento_slug text)
returns table (tipo text, titulo text, url text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  if _meu_participante(p_evento_slug) is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;

  return query
    select m.tipo, m.titulo, m.url
    from materiais_cio m
    where m.ativo
    order by m.tipo, m.ordem, m.titulo;
end;
$$;

revoke execute on function part_listar_materiais_cio(text) from public, anon;
grant execute on function part_listar_materiais_cio(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 5.7 — relatorio do Lounge, no formato do mailing list
-- ---------------------------------------------------------------------
create or replace function admin_rel_lounge(p_evento_slug text)
returns table (
  lounge text, empresa text, cota text, segmento text, site text,
  contato_nome text, contato_email text, contato_telefone text
)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select p.lounge, p.empresa, c.nome, p.segmento, p.site,
           u.nome, u.email, u.telefone
    from patrocinadores p
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    left join cotas c on c.id = p.cota_id
    left join usuarios_patrocinador u on u.empresa_id = p.empresa_id and u.ativo
    where p.lounge is not null and p.status = 'ativo'
    order by p.lounge, p.empresa, u.nome nulls last;
end;
$$;

revoke execute on function admin_rel_lounge(text) from public, anon;
grant execute on function admin_rel_lounge(text) to authenticated, service_role;
