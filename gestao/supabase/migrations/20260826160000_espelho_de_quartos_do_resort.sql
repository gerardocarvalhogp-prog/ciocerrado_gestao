-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Espelho de quartos do resort: importar o mapa em vez de digitar faixa.
--
-- O QUE O RESORT MANDA
--
-- Uma aba por predio ("Alexânia 1", "Alexânia 2") com duas partes:
--
--   1. um dicionario de categorias no topo — codigo, nome e descricao
--      em prosa ("2 camas queen e 1 cama de viuva")
--   2. o mapa, uma linha por apartamento: PREDIO, ANDAR, CORREDOR,
--      Nº DO APTO, CATEGORIA, DISTRIBUICAO, OCUPACAO, QTDE
--
-- Sao 424 apartamentos em 9 categorias na edicao de 2026. Cadastrar
-- isso por faixa de numeracao, escolhendo um tipo por faixa, e
-- transcrever um mapa que ja existe — e transcrever erra.
--
-- O QUE ESTA FUNCAO IMPORTA, E O QUE ELA NAO INVENTA
--
-- Importa o que o mapa AFIRMA: numero, predio, andar, corredor e o
-- codigo da categoria. Isso e fato, vem do resort e nao admite
-- interpretacao.
--
-- NAO deduz capacidade a partir da descricao. "2 camas queen e 1 cama
-- de viuva" pode ser 3, 4 ou 5 pessoas dependendo do que o resort
-- aceita cobrar, e errar isso e alocar gente que nao cabe. A capacidade
-- e o tipo (que e rotulo de preco) ficam na tabela de categorias, com
-- um padrao conservador, para a organizacao confirmar com o hotel.
--
-- A COLUNA "QTDE" DO MAPA NAO E CAPACIDADE
--
-- E quanta gente esta alocada naquele apartamento na planilha — o mapa
-- vem preenchido do ano anterior. Importa-la como capacidade faria um
-- apartamento vazio virar capacidade zero.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. ONDE FICA CADA QUARTO
-- ---------------------------------------------------------------------
alter table quartos add column if not exists categoria text;
alter table quartos add column if not exists andar text;
alter table quartos add column if not exists corredor text;

comment on column quartos.categoria is
  'Codigo da categoria no resort (SUP, SUPVAR, SUPTPL...). E como o hotel se refere ao quarto.';

-- ---------------------------------------------------------------------
-- 2. O DICIONARIO DE CATEGORIAS
--
-- Uma por evento: o resort muda o catalogo entre edicoes, e a de 2027
-- nao precisa herdar engano da de 2026.
-- ---------------------------------------------------------------------
create table if not exists categorias_quarto (
  id          uuid primary key default gen_random_uuid(),
  evento_id   uuid not null references eventos(id) on delete cascade,
  codigo      text not null,
  nome        text,
  descricao   text,
  -- padrao conservador de proposito: melhor a organizacao aumentar
  -- sabendo, do que o sistema prometer cama que nao existe
  capacidade  int  not null default 2,
  tipo        text not null default 'duplo',
  created_at  timestamptz default now(),
  updated_at  timestamptz default now(),
  constraint categorias_quarto_tipo_check check (tipo in ('single','duplo','triplo')),
  constraint categorias_quarto_cap_check  check (capacidade between 1 and 6)
);

create unique index if not exists categorias_quarto_uk
  on categorias_quarto (evento_id, upper(codigo));

alter table categorias_quarto enable row level security;

drop policy if exists categorias_quarto_staff on categorias_quarto;
create policy categorias_quarto_staff on categorias_quarto
  for all to authenticated using (is_staff()) with check (is_staff());

-- ---------------------------------------------------------------------
-- 3. A IMPORTACAO
--
-- Recebe as linhas ja lidas pelo navegador (SheetJS), como o import do
-- Sympla ja faz. Fazer o Postgres ler xlsx seria pior: o arquivo muda
-- de formato a cada ano e o erro apareceria longe de quem pode
-- corrigi-lo.
-- ---------------------------------------------------------------------
create or replace function admin_importar_mapa_quartos(
  p_evento_slug text,
  p_categorias jsonb default '[]'::jsonb,
  p_quartos jsonb default '[]'::jsonb
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_cat int := 0; v_novos int := 0; v_atual int := 0;
  v_x jsonb; v_num text;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;

  -- categorias primeiro: os quartos referenciam o codigo
  for v_x in select * from jsonb_array_elements(coalesce(p_categorias,'[]'::jsonb))
  loop
    if coalesce(trim(v_x ->> 'codigo'),'') = '' then continue; end if;

    insert into categorias_quarto (evento_id, codigo, nome, descricao)
    values (v_evento, upper(trim(v_x ->> 'codigo')),
            nullif(trim(v_x ->> 'nome'),''),
            nullif(trim(v_x ->> 'descricao'),''))
    on conflict (evento_id, upper(codigo)) do update set
      -- nome e descricao acompanham o arquivo; capacidade e tipo NAO,
      -- porque foram ajustados a mao depois de falar com o resort
      nome      = coalesce(excluded.nome, categorias_quarto.nome),
      descricao = coalesce(excluded.descricao, categorias_quarto.descricao),
      updated_at = now();
    v_cat := v_cat + 1;
  end loop;

  for v_x in select * from jsonb_array_elements(coalesce(p_quartos,'[]'::jsonb))
  loop
    v_num := nullif(trim(v_x ->> 'numero'),'');
    if v_num is null then continue; end if;

    insert into quartos (evento_id, numero, tipo, capacidade, status,
                         bloco, andar, corredor, categoria)
    select v_evento, v_num,
           coalesce(c.tipo, 'duplo'), coalesce(c.capacidade, 2), 'disponivel',
           nullif(trim(v_x ->> 'bloco'),''),
           nullif(trim(v_x ->> 'andar'),''),
           nullif(trim(v_x ->> 'corredor'),''),
           nullif(upper(trim(v_x ->> 'categoria')),'')
    from (select 1) z
    left join categorias_quarto c
      on c.evento_id = v_evento
     and upper(c.codigo) = upper(trim(v_x ->> 'categoria'))
    -- o `where` repete o predicado do indice: quartos_uk e PARCIAL
    -- (`where numero is not null`), e sem ele o Postgres nao acha a
    -- restricao e recusa o on conflict
    on conflict (evento_id, numero) where numero is not null do update set
      -- so o mapa manda aqui. Tipo e capacidade nao sao tocados na
      -- atualizacao: quem os define e a categoria, e quem define a
      -- categoria e a organizacao junto com o hotel.
      bloco     = coalesce(excluded.bloco, quartos.bloco),
      andar     = coalesce(excluded.andar, quartos.andar),
      corredor  = coalesce(excluded.corredor, quartos.corredor),
      categoria = coalesce(excluded.categoria, quartos.categoria);

  end loop;

  -- Contar inseridos e atualizados separadamente exigiria RETURNING por
  -- linha; o que a organizacao precisa saber e se o total bate com o
  -- mapa que ela acabou de subir.
  select count(*) into v_novos from quartos where evento_id = v_evento;
  select count(*) into v_atual from quartos
   where evento_id = v_evento and categoria is not null;

  return jsonb_build_object('ok', true,
    'categorias', v_cat,
    'linhas_recebidas', jsonb_array_length(coalesce(p_quartos,'[]'::jsonb)),
    'quartos_no_evento', v_novos,
    'com_categoria', v_atual);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. AJUSTAR CAPACIDADE E TIPO DE UMA CATEGORIA
--
-- E aqui que a organizacao registra o que combinou com o resort. Mexer
-- na categoria reflete em todos os quartos dela — que e o ponto: sao
-- 101 apartamentos SUP, e corrigir um a um seria transcrever de novo.
-- ---------------------------------------------------------------------
create or replace function admin_salvar_categoria_quarto(
  p_evento_slug text,
  p_codigo text,
  p_capacidade int,
  p_tipo text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_n int;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if p_tipo not in ('single','duplo','triplo') then
    raise exception 'Tipo invalido: %', p_tipo using errcode='22023';
  end if;
  if p_capacidade is null or p_capacidade < 1 or p_capacidade > 6 then
    raise exception 'Capacidade fora do razoavel: %', p_capacidade using errcode='22023';
  end if;

  update categorias_quarto set
    capacidade = p_capacidade, tipo = p_tipo, updated_at = now()
  where evento_id = v_evento and upper(codigo) = upper(trim(p_codigo));

  if not found then
    raise exception 'Categoria % nao encontrada neste evento', p_codigo
      using errcode='P0002';
  end if;

  -- propaga para os quartos daquela categoria
  update quartos q set capacidade = p_capacidade, tipo = p_tipo
   where q.evento_id = v_evento
     and upper(q.categoria) = upper(trim(p_codigo));
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'quartos_atualizados', v_n);
end;
$$;

create or replace function admin_listar_categorias_quarto(p_evento_slug text)
returns table (codigo text, nome text, descricao text,
               capacidade int, tipo text, quartos bigint)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select c.codigo, c.nome, c.descricao, c.capacidade, c.tipo,
           (select count(*) from quartos q
             where q.evento_id = c.evento_id
               and upper(q.categoria) = upper(c.codigo))
    from categorias_quarto c
    join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
    order by c.codigo;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. PERMISSAO
-- ---------------------------------------------------------------------
revoke execute on function admin_importar_mapa_quartos(text, jsonb, jsonb) from public, anon;
revoke execute on function admin_salvar_categoria_quarto(text, text, int, text) from public, anon;
revoke execute on function admin_listar_categorias_quarto(text) from public, anon;
grant execute on function admin_importar_mapa_quartos(text, jsonb, jsonb) to authenticated, service_role;
grant execute on function admin_salvar_categoria_quarto(text, text, int, text) to authenticated, service_role;
grant execute on function admin_listar_categorias_quarto(text) to authenticated, service_role;

revoke all on table categorias_quarto from anon, authenticated;
