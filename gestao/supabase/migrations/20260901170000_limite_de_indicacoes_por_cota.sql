-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Limite de indicações de CIO por cota, consistido no portal.
--
-- NULL = sem limite (padrao conservador de sempre neste projeto: nao
-- inventa numero — evento que nunca configurou continua exatamente
-- como hoje, indicacao ilimitada).
--
-- O QUE CONTA PRA COTA
--
-- 'nova', 'convidado' e 'inscrito' consomem a cota — sao indicacoes
-- de verdade, em algum ponto do caminho. 'duplicado' (a pessoa ja
-- estava na base) e 'recusado' (a organizacao recusou) NAO consomem:
-- nao seria justo cobrar do patrocinador uma vaga que a organizacao
-- decidiu nao aproveitar.
-- =====================================================================

set search_path = gestao, public;

alter table cotas add column if not exists limite_indicacoes integer;
alter table cotas drop constraint if exists cotas_limite_indicacoes_check;
alter table cotas add constraint cotas_limite_indicacoes_check
  check (limite_indicacoes is null or limite_indicacoes >= 0);
comment on column cotas.limite_indicacoes is
  'Quantas indicacoes de CIO essa cota pode fazer. NULL = sem limite.';

-- ---------------------------------------------------------------------
-- 1. CADASTRO DA COTA GANHA O CAMPO
-- ---------------------------------------------------------------------
create or replace function admin_salvar_cota(
  p_evento_slug text, p_nome text, p_ordem integer,
  p_quartos jsonb DEFAULT '{}'::jsonb, p_vagas_mesa integer DEFAULT 0,
  p_reuniao boolean DEFAULT false, p_jantar boolean DEFAULT false,
  p_prazo_indicacao date DEFAULT NULL::date, p_janela_horas integer DEFAULT NULL::integer,
  p_limite_indicacoes integer DEFAULT NULL::integer
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
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
  if p_janela_horas is not null and p_janela_horas <= 0 then
    raise exception 'A janela em horas comeca em 1' using errcode='22023';
  end if;
  if p_limite_indicacoes is not null and p_limite_indicacoes < 0 then
    raise exception 'O limite de indicacoes nao pode ser negativo' using errcode='22023';
  end if;

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
                     quartos_incluidos, tipo_quarto_padrao, prazo_indicacao,
                     janela_horas, limite_indicacoes)
  values (v_evento, trim(p_nome), v_ordem, coalesce(p_vagas_mesa,0),
          p_reuniao, p_jantar, 0, 'duplo', p_prazo_indicacao, p_janela_horas,
          p_limite_indicacoes)
  on conflict (evento_id, nome) do update set
    ordem_prioridade = excluded.ordem_prioridade,
    vagas_mesa_redonda = excluded.vagas_mesa_redonda,
    tem_reuniao_exclusiva = excluded.tem_reuniao_exclusiva,
    tem_jantar = excluded.tem_jantar,
    prazo_indicacao = excluded.prazo_indicacao,
    janela_horas = excluded.janela_horas,
    limite_indicacoes = excluded.limite_indicacoes
  returning id into v_cota;

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

  update cotas set quartos_incluidos = v_total where id = v_cota;

  return jsonb_build_object('ok', true, 'id', v_cota, 'total_quartos', v_total);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. LISTAGEM DA COTA EXPOE O LIMITE (pra tela prefill no editar)
-- ---------------------------------------------------------------------
drop function if exists admin_listar_cotas(text);

create or replace function admin_listar_cotas(p_evento_slug text)
returns table (
  id uuid, nome text, ordem_prioridade integer, quartos jsonb,
  total_quartos bigint, vagas_mesa_redonda integer,
  tem_reuniao_exclusiva boolean, tem_jantar boolean,
  patrocinadores bigint, lista_patrocinadores jsonb,
  prazo_indicacao date, janela_horas integer, limite_indicacoes integer
)
language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
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
                     where p.cota_id = c.id and p.status = 'ativo'), '[]'::jsonb),
           c.prazo_indicacao, c.janela_horas, c.limite_indicacoes
    from cotas c
    join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. VALIDA NO PORTAL, NA HORA DE INDICAR
-- ---------------------------------------------------------------------
create or replace function patro_indicar_cio(p_patrocinador_id uuid, p_nome text, p_empresa text DEFAULT NULL::text, p_cargo text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_telefone text DEFAULT NULL::text, p_observacao text DEFAULT NULL::text)
returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare
  v_evento uuid;
  v_dup    uuid;
  v_id     uuid;
  v_limite int;
  v_usadas int;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Nome e obrigatorio' using errcode = '22023';
  end if;

  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;

  select c.limite_indicacoes into v_limite
  from patrocinadores p join cotas c on c.id = p.cota_id
  where p.id = p_patrocinador_id;

  if v_limite is not null then
    select count(*) into v_usadas from indicacoes
     where patrocinador_id = p_patrocinador_id
       and status in ('nova','convidado','inscrito');
    if v_usadas >= v_limite then
      raise exception 'Sua cota já indicou o máximo de % CIO(s) — fale com a organização se precisar de mais', v_limite
        using errcode = '55000';
    end if;
  end if;

  select g.id into v_dup from gestores g
   where p_email is not null and g.email_norm = norm_doc(p_email);

  insert into indicacoes (evento_id, patrocinador_id, nome, empresa, cargo,
                          email, telefone, observacao, status, gestor_id)
  values (v_evento, p_patrocinador_id, trim(p_nome), p_empresa, p_cargo,
          p_email, p_telefone, p_observacao,
          case when v_dup is not null then 'duplicado' else 'nova' end,
          v_dup)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id,
                            'ja_na_base', v_dup is not null);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. QUANTO JA USOU / QUANTO PODE — pra tela mostrar antes de tentar
-- ---------------------------------------------------------------------
create or replace function patro_minhas_indicacoes_resumo(p_patrocinador_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_limite int; v_usadas int;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  select c.limite_indicacoes into v_limite
  from patrocinadores p join cotas c on c.id = p.cota_id
  where p.id = p_patrocinador_id;

  select count(*) into v_usadas from indicacoes
   where patrocinador_id = p_patrocinador_id
     and status in ('nova','convidado','inscrito');

  return jsonb_build_object('limite', v_limite, 'usadas', v_usadas);
end;
$$;

revoke execute on function admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer) from public, anon;
revoke execute on function admin_listar_cotas(text) from public, anon;
revoke execute on function patro_indicar_cio(uuid,text,text,text,text,text,text) from public, anon;
revoke execute on function patro_minhas_indicacoes_resumo(uuid) from public, anon;
grant execute on function admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer) to authenticated, service_role;
grant execute on function admin_listar_cotas(text) to authenticated, service_role;
grant execute on function patro_indicar_cio(uuid,text,text,text,text,text,text) to authenticated, service_role;
grant execute on function patro_minhas_indicacoes_resumo(uuid) to authenticated, service_role;
