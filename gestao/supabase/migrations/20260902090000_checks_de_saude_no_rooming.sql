-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Checks de saude/mobilidade/alergia/berco no rooming do CIO.
--
-- Item do backlog: "dificuldade de mobilidade, alergia com campo de
-- detalhe, pergunta de berco para criancas, observacoes gerais" — sem
-- isso a equipe so descobria essas necessidades no check-in, tarde
-- demais pra preparar o quarto.
--
-- Berco nao e validado contra idade no banco: a tela so oferece a
-- pergunta pra criancas, e travar aqui so pra "crianca com mais de 5
-- anos que ainda usa berco" seria regra demais pra um dado que a
-- familia sabe melhor que o sistema.
-- =====================================================================

set search_path = gestao, public;

alter table ocupantes add column if not exists dificuldade_mobilidade boolean not null default false;
alter table ocupantes add column if not exists tem_alergia boolean not null default false;
alter table ocupantes add column if not exists alergia_detalhe text;
alter table ocupantes add column if not exists precisa_berco boolean not null default false;
alter table ocupantes add column if not exists observacoes text;

comment on column ocupantes.dificuldade_mobilidade is 'Marcado pelo proprio CIO/familiar no rooming — avisa a equipe pra priorizar quarto acessivel.';
comment on column ocupantes.tem_alergia is 'Alergia declarada, detalhe livre em alergia_detalhe.';
comment on column ocupantes.precisa_berco is 'So faz sentido pra criancas pequenas — a tela decide quando perguntar, o banco so guarda a resposta.';

-- ---------------------------------------------------------------------
-- 1. SALVAR ROOMING GANHA OS CAMPOS (titular + cada familiar no jsonb)
-- ---------------------------------------------------------------------
drop function if exists part_salvar_rooming(text,jsonb,boolean,text);

create or replace function part_salvar_rooming(
  p_evento_slug text, p_acompanhantes jsonb,
  p_usa_transfer boolean DEFAULT NULL::boolean,
  p_transfer_origem text DEFAULT NULL::text,
  p_dificuldade_mobilidade boolean DEFAULT NULL::boolean,
  p_tem_alergia boolean DEFAULT NULL::boolean,
  p_alergia_detalhe text DEFAULT NULL::text,
  p_observacoes text DEFAULT NULL::text
)
returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare
  v_part   uuid;
  v_res    uuid;
  v_status jsonb;
  v_prazo  date;
  v_limite date;
  v_item   jsonb;
  v_nasc   date;
  v_qtd    int;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;

  perform _exige_origem_transfer(p_transfer_origem);

  v_status := part_meu_status(p_evento_slug);

  if not (v_status ->> 'rooming_liberado')::boolean then
    raise exception 'Rooming liberado apenas apos a assinatura do contrato'
      using errcode = '55000';
  end if;

  v_prazo := (v_status ->> 'prazo_rooming')::date;
  if v_prazo is not null and current_date > v_prazo and not is_staff() then
    raise exception 'Prazo de rooming encerrado em %', v_prazo
      using errcode = '55000';
  end if;

  v_qtd := jsonb_array_length(coalesce(p_acompanhantes,'[]'::jsonb)) + 1;
  if v_qtd > _capacidade_quarto() then
    raise exception
      'O quarto comporta % pessoa(s), incluindo voce; foram informadas %. Acima disso e quarto adicional.',
      _capacidade_quarto(), v_qtd using errcode = '22023';
  end if;

  select coalesce(e.data_inicio, current_date) into v_limite
  from eventos e where e.slug = p_evento_slug;

  for v_item in select * from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb))
  loop
    if coalesce(trim(v_item ->> 'nome'),'') = '' then
      raise exception 'Todo familiar precisa de nome' using errcode = '22023';
    end if;
    v_nasc := nullif(v_item ->> 'data_nascimento','')::date;
    if v_nasc is not null and v_nasc > v_limite then
      raise exception 'Data de nascimento depois do início do evento (%): %', v_limite, v_nasc
        using errcode = '22023';
    end if;
    perform _exige_origem_transfer(nullif(v_item ->> 'transfer_origem',''));
    if coalesce(v_item ->> 'tipo','adulto') = 'crianca' and v_nasc is null then
      raise exception 'Informe a data de nascimento das criancas'
        using errcode = '22023';
    end if;
  end loop;

  v_res := _garantir_reserva(v_part);

  delete from ocupantes where reserva_id = v_res and tipo <> 'titular';

  insert into ocupantes (reserva_id, nome, cpf, data_nascimento, tipo,
                         usa_transfer, transfer_origem, categoria_cracha,
                         dificuldade_mobilidade, tem_alergia, alergia_detalhe,
                         precisa_berco, observacoes)
  select v_res,
         trim(x ->> 'nome'),
         nullif(x ->> 'cpf',''),
         nullif(x ->> 'data_nascimento','')::date,
         coalesce(nullif(x ->> 'tipo',''), 'adulto'),
         (x ->> 'usa_transfer')::boolean,
         nullif(x ->> 'transfer_origem',''),
         'FAMILIAR',
         coalesce((x ->> 'dificuldade_mobilidade')::boolean, false),
         coalesce((x ->> 'tem_alergia')::boolean, false),
         nullif(x ->> 'alergia_detalhe',''),
         coalesce((x ->> 'precisa_berco')::boolean, false),
         nullif(x ->> 'observacoes','')
  from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb)) x;

  insert into ocupantes (reserva_id, nome, tipo, categoria_cracha, email)
  select v_res, g.nome, 'titular', 'PROTAGONISTA', g.email
  from participantes pa join gestores g on g.id = pa.gestor_id
  where pa.id = v_part
    and not exists (select 1 from ocupantes o
                    where o.reserva_id = v_res and o.tipo = 'titular');

  update ocupantes set
    usa_transfer            = coalesce(p_usa_transfer, usa_transfer),
    transfer_origem         = coalesce(p_transfer_origem, transfer_origem),
    dificuldade_mobilidade  = coalesce(p_dificuldade_mobilidade, dificuldade_mobilidade),
    tem_alergia             = coalesce(p_tem_alergia, tem_alergia),
    alergia_detalhe         = coalesce(p_alergia_detalhe, alergia_detalhe),
    observacoes             = coalesce(p_observacoes, observacoes)
   where reserva_id = v_res and tipo = 'titular';

  update reservas set
    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),
    transfer_origem = coalesce(p_transfer_origem, transfer_origem),
    status          = 'completo',
    completo_em     = coalesce(completo_em, now())
  where id = v_res;

  insert into notificacoes (evento_id, destinatario, tipo, assunto)
  select r.evento_id, g.email, 'rooming_ok', 'Dados de hospedagem confirmados'
  from reservas r
  join participantes pa on pa.id = r.participante_id
  join gestores g on g.id = pa.gestor_id
  where r.id = v_res;

  return part_calcular_fatura(p_evento_slug);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. LISTAR ROOMING DEVOLVE OS CAMPOS (prefill da tela)
-- ---------------------------------------------------------------------
drop function if exists part_listar_rooming(text);

create or replace function part_listar_rooming(p_evento_slug text)
returns table (
  id uuid, nome text, cpf text, data_nascimento date, tipo text,
  usa_transfer boolean, transfer_origem text,
  dificuldade_mobilidade boolean, tem_alergia boolean, alergia_detalhe text,
  precisa_berco boolean, observacoes text
)
language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
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
    where r.participante_id = v_part and r.status <> 'cancelado'
    order by (o.tipo = 'titular') desc, o.created_at;
end;
$$;

revoke execute on function part_salvar_rooming(text,jsonb,boolean,text,boolean,boolean,text,text) from public, anon;
revoke execute on function part_listar_rooming(text) from public, anon;
grant execute on function part_salvar_rooming(text,jsonb,boolean,text,boolean,boolean,text,text) to authenticated, service_role;
grant execute on function part_listar_rooming(text) to authenticated, service_role;
