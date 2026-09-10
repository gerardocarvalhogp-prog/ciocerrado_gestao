-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Bloco 4 (Fase 2) — patrocinador vira cadastro unico de empresa,
-- reaproveitado entre eventos.
--
-- O QUE MUDA DE SIGNIFICADO
--
-- `patrocinadores` deixa de SER a empresa e passa a ser o VINCULO dela
-- com um evento (cota, valor, status, quartos extras) — a mesma leitura
-- que `reservas` ja tem para quarto, ou `sessoes` para mesa redonda.
-- Quem a empresa E vira responsabilidade de `empresas` (tabela que ja
-- existia para o cadastro de gestores, desde 25/08 — reaproveitada
-- aqui, nao criada do zero).
--
-- Nenhuma coluna nem tabela dependente de patrocinador_id muda de
-- lugar (brindes, indicacoes, reservas, sessoes, faturas, contratos,
-- checkins, patrocinador_uploads, mapa_empresa_app continuam apontando
-- pro vinculo, exatamente como hoje) — o unico ponto que muda de fato
-- e' `meus_patrocinadores()`, que passa a devolver todo vinculo de toda
-- empresa que o usuario acessa, nao so o vinculo que originou o login.
-- Isso e' suficiente pra login e cadastro de empresa serem
-- reaproveitados entre eventos sem tocar nas 21 funcoes patro_* nem
-- em portal.html.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. EMPRESAS ganha os campos de perfil que hoje so existem em
--    patrocinadores — o que "a empresa e" nao muda por evento.
-- ---------------------------------------------------------------------
alter table empresas add column if not exists resumo text;
alter table empresas add column if not exists o_que_vende text;
alter table empresas add column if not exists natureza text;

alter table empresas drop constraint if exists empresas_natureza_check;
alter table empresas add constraint empresas_natureza_check
  check (natureza is null or natureza in ('privada','hibrida','publica'));

-- ---------------------------------------------------------------------
-- 2. patrocinadores ganha empresa_id — o vinculo aponta pra empresa
-- ---------------------------------------------------------------------
alter table patrocinadores add column if not exists empresa_id uuid references empresas(id);

-- Backfill: casa por nome normalizado com empresa ja existente; cria a
-- que faltar. Nao apaga nem sobrescreve dado que a empresa ja tinha —
-- so completa o que estava vazio.
do $$
declare v_p record; v_emp uuid;
begin
  for v_p in
    select id, empresa, cnpj, segmento, o_que_vende, resumo, natureza, site, cidade, estado
    from patrocinadores where empresa_id is null
  loop
    select id into v_emp from empresas where lower(trim(nome)) = lower(trim(v_p.empresa));

    if v_emp is null then
      insert into empresas (nome, cnpj, segmento, site, cidade, estado, resumo, o_que_vende, natureza)
      values (trim(v_p.empresa), v_p.cnpj, v_p.segmento, v_p.site, v_p.cidade, v_p.estado,
              v_p.resumo, v_p.o_que_vende, v_p.natureza)
      returning id into v_emp;
    else
      update empresas set
        cnpj        = coalesce(empresas.cnpj, v_p.cnpj),
        segmento    = coalesce(empresas.segmento, v_p.segmento),
        site        = coalesce(empresas.site, v_p.site),
        cidade      = coalesce(empresas.cidade, v_p.cidade),
        estado      = coalesce(empresas.estado, v_p.estado),
        resumo      = coalesce(empresas.resumo, v_p.resumo),
        o_que_vende = coalesce(empresas.o_que_vende, v_p.o_que_vende),
        natureza    = coalesce(empresas.natureza, v_p.natureza)
      where id = v_emp;
    end if;

    update patrocinadores set empresa_id = v_emp where id = v_p.id;
  end loop;
end $$;

alter table patrocinadores alter column empresa_id set not null;
create index if not exists patrocinadores_empresa_id_idx on patrocinadores(empresa_id);

-- Mesma empresa nao pode ter dois vinculos com o mesmo evento — a
-- unicidade por nome (patrocinadores_uk) continua existindo tambem,
-- as duas nunca vao divergir porque quem escreve e' sempre a mesma
-- funcao.
create unique index if not exists patrocinadores_evento_empresa_uk
  on patrocinadores (evento_id, empresa_id);

-- ---------------------------------------------------------------------
-- 3. usuarios_patrocinador passa a pertencer a' EMPRESA, nao ao
--    vinculo por evento — e' o que faz o login ser reaproveitado.
-- ---------------------------------------------------------------------
alter table usuarios_patrocinador add column if not exists empresa_id uuid references empresas(id);

update usuarios_patrocinador u
set empresa_id = p.empresa_id
from patrocinadores p
where u.patrocinador_id = p.id and u.empresa_id is null;

alter table usuarios_patrocinador alter column empresa_id set not null;

-- patrocinador_id vira so o registro historico de qual vinculo
-- originou o cadastro — nao decide mais acesso (ver meus_patrocinadores
-- abaixo). Por isso a FK muda de CASCADE pra SET NULL: apagar o
-- vinculo de um evento antigo nao pode levar junto o login que ainda
-- serve pra outros eventos da mesma empresa.
alter table usuarios_patrocinador alter column patrocinador_id drop not null;
alter table usuarios_patrocinador drop constraint if exists usuarios_patrocinador_patrocinador_id_fkey;
alter table usuarios_patrocinador add constraint usuarios_patrocinador_patrocinador_id_fkey
  foreign key (patrocinador_id) references patrocinadores(id) on delete set null;
comment on column usuarios_patrocinador.patrocinador_id is
  'Historico de qual vinculo originou o cadastro do usuario. Nao decide mais autorizacao — ver empresa_id e meus_patrocinadores().';

create unique index if not exists usuarios_patro_empresa_uk
  on usuarios_patrocinador (empresa_id, email_norm);

-- ---------------------------------------------------------------------
-- 3a. REDE DE SEGURANCA PRA INSERT DIRETO (fixture de teste, seed,
--     qualquer coisa que nao passe por admin_salvar_patrocinador /
--     admin_salvar_usuario_patro). Sem isso, `empresa_id NOT NULL`
--     quebraria `supabase/tests/01-cenario-setup.sql` e
--     `07-regras-de-dinheiro.sql`, que inserem direto na tabela como
--     `postgres` — jeito documentado e deliberado de montar cenario de
--     teste, nao um caminho de cliente.
-- ---------------------------------------------------------------------
create or replace function _preencher_empresa_id_patrocinador()
returns trigger language plpgsql as $$
declare v_emp uuid;
begin
  if new.empresa_id is null then
    select id into v_emp from empresas where lower(trim(nome)) = lower(trim(new.empresa));
    if v_emp is null then
      insert into empresas (nome) values (trim(new.empresa)) returning id into v_emp;
    end if;
    new.empresa_id := v_emp;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_patrocinador_empresa_id on patrocinadores;
create trigger trg_patrocinador_empresa_id
  before insert on patrocinadores
  for each row execute function _preencher_empresa_id_patrocinador();

create or replace function _preencher_empresa_id_usuario_patro()
returns trigger language plpgsql as $$
begin
  if new.empresa_id is null and new.patrocinador_id is not null then
    select empresa_id into new.empresa_id from patrocinadores where id = new.patrocinador_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_usuario_patro_empresa_id on usuarios_patrocinador;
create trigger trg_usuario_patro_empresa_id
  before insert on usuarios_patrocinador
  for each row execute function _preencher_empresa_id_usuario_patro();

-- ---------------------------------------------------------------------
-- 4. O NUCLEO DO COMPARTILHAMENTO
--
-- meus_patrocinadores() continua devolvendo SETOF uuid de
-- patrocinadores.id (vinculo), exatamente como sempre devolveu — so
-- muda COMO calcula: em vez de "os vinculos que o usuario logou uma
-- vez", passa a ser "todo vinculo de toda empresa que o usuario
-- acessa". Como o contrato (tipo de retorno) nao muda, as 21 funcoes
-- patro_* que chamam _exige_patrocinador/pode_ver_patrocinador, a RLS
-- das 7 tabelas com policy de patrocinador, e portal.html inteiro
-- continuam funcionando sem nenhum ajuste.
-- ---------------------------------------------------------------------
create or replace function meus_patrocinadores()
returns setof uuid
language sql stable security definer
set search_path to 'gestao', 'public' as $$
  select p.id
  from patrocinadores p
  join usuarios_patrocinador u on u.empresa_id = p.empresa_id
  where u.email_norm = norm_doc(auth.jwt() ->> 'email') and u.ativo;
$$;

-- ---------------------------------------------------------------------
-- 5. CADASTRO: admin_salvar_patrocinador passa a resolver a empresa
--    por nome (cria se nao existir, atualiza o cadastro unico se
--    existir) antes de gravar o vinculo do evento. Assinatura
--    identica a de hoje — nenhuma chamada em admin.html precisa mudar.
--
--    Restaura tambem a geracao automatica de quartos da cota ao
--    salvar (perdida sem querer na reescrita de 28/08 que acrescentou
--    o campo lounge — o admin_gerar_quartos_cota continuava existindo,
--    so parou de ser chamado daqui; o efeito visivel era o patrocinador
--    entrar no portal e ver "sua cota ainda nao tem quartos liberados"
--    ate alguem lembrar de clicar em "Gerar quartos das cotas").
-- ---------------------------------------------------------------------
create or replace function admin_salvar_patrocinador(
  p_evento_slug text, p_empresa text,
  p_cota_nome text DEFAULT NULL::text,
  p_cnpj text DEFAULT NULL::text,
  p_segmento text DEFAULT NULL::text,
  p_o_que_vende text DEFAULT NULL::text,
  p_quartos_extras integer DEFAULT 0,
  p_vagas_mesa_override integer DEFAULT NULL::integer,
  p_status text DEFAULT 'ativo'::text,
  p_site text DEFAULT NULL::text,
  p_resumo text DEFAULT NULL::text,
  p_natureza text DEFAULT NULL::text,
  p_cidade text DEFAULT NULL::text,
  p_estado text DEFAULT NULL::text,
  p_lounge text DEFAULT NULL::text
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare v_evento uuid; v_cota uuid; v_id uuid; v_empresa uuid; v_tem_cota boolean;
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

  -- resolve a empresa (cadastro unico): casa por nome, cria se nao
  -- achar, completa/corrige se achar — o dado enviado aqui alimenta
  -- todo evento futuro dessa empresa, nao so este.
  select id into v_empresa from empresas where lower(trim(nome)) = lower(trim(p_empresa));

  if v_empresa is null then
    insert into empresas (nome, cnpj, segmento, site, cidade, estado, resumo, o_que_vende, natureza)
    values (trim(p_empresa), p_cnpj, p_segmento, p_site, p_cidade, p_estado,
            p_resumo, p_o_que_vende, p_natureza)
    returning id into v_empresa;
  else
    update empresas set
      nome        = trim(p_empresa),
      cnpj        = coalesce(p_cnpj, empresas.cnpj),
      segmento    = coalesce(p_segmento, empresas.segmento),
      site        = coalesce(p_site, empresas.site),
      cidade      = coalesce(p_cidade, empresas.cidade),
      estado      = coalesce(p_estado, empresas.estado),
      resumo      = coalesce(p_resumo, empresas.resumo),
      o_que_vende = coalesce(p_o_que_vende, empresas.o_que_vende),
      natureza    = coalesce(p_natureza, empresas.natureza)
    where id = v_empresa;
  end if;

  insert into patrocinadores (evento_id, empresa_id, cota_id, empresa, cnpj, segmento,
                              o_que_vende, quartos_extras_cota,
                              vagas_mesa_override, status,
                              site, resumo, natureza, cidade, estado, lounge)
  values (v_evento, v_empresa, v_cota, trim(p_empresa), p_cnpj, p_segmento,
          p_o_que_vende, coalesce(p_quartos_extras,0),
          p_vagas_mesa_override, p_status,
          p_site, p_resumo, p_natureza, p_cidade, p_estado,
          nullif(trim(p_lounge),''))
  on conflict (evento_id, empresa_id) do update set
    cota_id = coalesce(excluded.cota_id, patrocinadores.cota_id),
    empresa = excluded.empresa,
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
    estado = coalesce(excluded.estado, patrocinadores.estado),
    lounge = coalesce(excluded.lounge, patrocinadores.lounge)
  returning id into v_id;

  if v_id is not null and coalesce(p_status,'ativo') = 'ativo' then
    select cota_id is not null into v_tem_cota from patrocinadores where id = v_id;
    if v_tem_cota then
      perform admin_gerar_quartos_cota(v_id);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'empresa_id', v_empresa);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. LISTAGEM: admin.html precisa do empresa_id pra abrir a tela de
--    usuarios da empresa certa (troca de patrocinador_id pra
--    empresa_id abaixo). Muda o RETURNS TABLE, entao exige DROP.
-- ---------------------------------------------------------------------
drop function if exists admin_listar_patrocinadores(text);

create function admin_listar_patrocinadores(p_evento_slug text) returns table(
  id uuid, empresa_id uuid, empresa text, cnpj text, segmento text, site text,
  resumo text, o_que_vende text, natureza text, cidade text,
  estado text, cota text, ordem integer, quartos_extras integer,
  vagas_mesa_override integer, status text,
  fechado_em timestamptz, enriquecido_em timestamptz,
  usuarios bigint, reservas bigint, lounge text
)
language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_staff();
  return query
    select p.id, p.empresa_id, p.empresa, p.cnpj, p.segmento,
           p.site, p.resumo, p.o_que_vende, p.natureza,
           p.cidade, p.estado,
           c.nome, c.ordem_prioridade, p.quartos_extras_cota,
           p.vagas_mesa_override, p.status, p.fechado_em, p.enriquecido_em,
           (select count(*) from usuarios_patrocinador u
             where u.empresa_id = p.empresa_id and u.ativo),
           (select count(*) from reservas r
             where r.patrocinador_id = p.id and r.status <> 'cancelado'),
           p.lounge
    from patrocinadores p
    left join cotas c on c.id = p.cota_id
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade nulls last, p.empresa;
end;
$$;

revoke all on function admin_listar_patrocinadores(text) from public, anon;
grant all on function admin_listar_patrocinadores(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 7. USUARIOS DO PORTAL: gerenciados por empresa, nao por vinculo —
--    um cadastro serve pra todo evento que a empresa participar.
--    Assinatura muda (patrocinador_id -> empresa_id), exige DROP.
-- ---------------------------------------------------------------------
drop function if exists admin_listar_usuarios_patro(uuid);

create function admin_listar_usuarios_patro(p_empresa_id uuid)
returns table(id uuid, email text, nome text, telefone text, ativo boolean)
language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_admin();
  return query
    select u.id, u.email, u.nome, u.telefone, u.ativo
    from usuarios_patrocinador u
    where u.empresa_id = p_empresa_id
    order by u.email;
end;
$$;

drop function if exists admin_salvar_usuario_patro(uuid, text, text, text);

create function admin_salvar_usuario_patro(
  p_empresa_id uuid, p_email text, p_nome text DEFAULT NULL::text, p_telefone text DEFAULT NULL::text
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_admin();

  if coalesce(trim(p_email),'') = '' then
    raise exception 'Informe o e-mail' using errcode='22023';
  end if;
  if not exists (select 1 from empresas where id = p_empresa_id) then
    raise exception 'Empresa nao encontrada' using errcode='P0002';
  end if;

  insert into usuarios_patrocinador (empresa_id, email, nome, telefone, ativo)
  values (p_empresa_id, lower(trim(p_email)), p_nome, p_telefone, true)
  on conflict (empresa_id, email_norm) do update set
    nome = coalesce(excluded.nome, usuarios_patrocinador.nome),
    telefone = coalesce(excluded.telefone, usuarios_patrocinador.telefone),
    ativo = true;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function admin_listar_usuarios_patro(uuid) from public, anon;
revoke all on function admin_salvar_usuario_patro(uuid, text, text, text) from public, anon;
grant all on function admin_listar_usuarios_patro(uuid) to authenticated, service_role;
grant all on function admin_salvar_usuario_patro(uuid, text, text, text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 8. ENRIQUECIMENTO POR IA: gravava so no vinculo do evento atual —
--    o achado sobre a empresa (site, resumo, segmento etc.) precisa
--    valer pra todo evento dela, nao so o que estava aberto na tela
--    quando alguem clicou em "IA". Mesma assinatura de hoje, so o
--    corpo muda: nao exige DROP.
-- ---------------------------------------------------------------------
create or replace function admin_enriquecer_patrocinador(
  p_id uuid, p_site text DEFAULT NULL::text, p_resumo text DEFAULT NULL::text,
  p_o_que_vende text DEFAULT NULL::text, p_segmento text DEFAULT NULL::text,
  p_natureza text DEFAULT NULL::text, p_cidade text DEFAULT NULL::text,
  p_estado text DEFAULT NULL::text, p_cnpj text DEFAULT NULL::text
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare v_empresa uuid;
begin
  perform _exige_admin();

  select empresa_id into v_empresa from patrocinadores where id = p_id;
  if v_empresa is null then
    raise exception 'Patrocinador nao encontrado' using errcode='P0002';
  end if;

  update patrocinadores set
    site        = coalesce(nullif(trim(p_site),''), site),
    resumo      = coalesce(nullif(trim(p_resumo),''), resumo),
    o_que_vende = coalesce(nullif(trim(p_o_que_vende),''), o_que_vende),
    segmento    = coalesce(nullif(trim(p_segmento),''), segmento),
    natureza    = coalesce(nullif(trim(p_natureza),''), natureza),
    cidade      = coalesce(nullif(trim(p_cidade),''), cidade),
    estado      = coalesce(nullif(trim(p_estado),''), estado),
    cnpj        = coalesce(nullif(trim(p_cnpj),''), cnpj),
    enriquecido_em = now()
  where id = p_id;

  update empresas set
    site        = coalesce(nullif(trim(p_site),''), site),
    resumo      = coalesce(nullif(trim(p_resumo),''), resumo),
    o_que_vende = coalesce(nullif(trim(p_o_que_vende),''), o_que_vende),
    segmento    = coalesce(nullif(trim(p_segmento),''), segmento),
    natureza    = coalesce(nullif(trim(p_natureza),''), natureza),
    cidade      = coalesce(nullif(trim(p_cidade),''), cidade),
    estado      = coalesce(nullif(trim(p_estado),''), estado),
    cnpj        = coalesce(nullif(trim(p_cnpj),''), cnpj)
  where id = v_empresa;

  return jsonb_build_object('ok', true);
end;
$$;
