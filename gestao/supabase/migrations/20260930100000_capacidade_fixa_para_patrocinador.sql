-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- A capacidade de ate 4 pessoas por quarto (migration 20260826090000,
-- "capacidade de quatro") passa a valer SO para o CIO. Pedido do
-- organizador em 30/09/2026, depois de testar o portal do patrocinador
-- de verdade: pro patrocinador, a capacidade volta a ser fixa por tipo
-- de quarto (single 1, duplo 2, triplo 3), como era antes daquela
-- mudanca.
--
-- _capacidade_quarto() NAO muda — continua sendo o teto flat de 4 e
-- continua sendo o que part_salvar_rooming (rooming do CIO) usa. Cria
-- _capacidade_quarto_patrocinador(tipo), so para os dois lugares do
-- patrocinador que usavam a antiga: patro_salvar_quarto (validacao) e
-- patro_listar_quartos (o numero que a tela mostra — precisa bater com
-- o que a validacao aceita, senao a tela promete 4 e o banco recusa
-- em 3).
--
-- As duas funcoes do patrocinador sao recriadas com o texto exato das
-- versoes vigentes (patro_salvar_quarto em
-- 20260909120000_bloco1_quartos_rooming.sql, assinatura de 4
-- parametros; patro_listar_quartos em
-- 20260826110000_brinde_da_empresa.sql), trocando so a linha da
-- capacidade.
-- =====================================================================

set search_path = gestao, public;

create or replace function _capacidade_quarto_patrocinador(p_tipo text)
returns int language sql immutable
set search_path = gestao, public as $$
  select case p_tipo when 'single' then 1 when 'duplo' then 2 else 3 end;
$$;

comment on function _capacidade_quarto_patrocinador(text) is
  'Quantas pessoas cabem num quarto de patrocinador, por tipo. Diferente do CIO (_capacidade_quarto), que e teto fixo de 4 nao importa o tipo.';

-- ---------------------------------------------------------------------
-- patro_salvar_quarto
-- ---------------------------------------------------------------------
create or replace function patro_salvar_quarto(
  p_reserva_id uuid, p_ocupantes jsonb,
  p_usa_transfer boolean DEFAULT NULL::boolean,
  p_transfer_origem text DEFAULT NULL::text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_patro uuid;
  v_tipo  text;
  v_cap   int;
  v_qtd   int;
  v_item  jsonb;
  v_limite date;
  v_nasc  date;
begin
  select patrocinador_id, tipo into v_patro, v_tipo
  from reservas where id = p_reserva_id and status <> 'cancelado';

  if v_patro is null then
    raise exception 'Reserva nao encontrada' using errcode = 'P0002';
  end if;
  perform _exige_patrocinador(v_patro);

  -- capacidade do patrocinador e fixa por tipo (nao o teto flat de 4
  -- do CIO) — pedido do organizador em 30/09/2026
  v_cap := _capacidade_quarto_patrocinador(v_tipo);
  v_qtd := jsonb_array_length(coalesce(p_ocupantes, '[]'::jsonb));

  if v_qtd > v_cap then
    raise exception 'O quarto comporta % pessoa(s); voce enviou %. Acima disso e quarto adicional.',
      v_cap, v_qtd using errcode = '22023';
  end if;

  perform _exige_origem_transfer(p_transfer_origem);

  select coalesce(e.data_inicio, current_date) into v_limite
  from reservas r join eventos e on e.id = r.evento_id
  where r.id = p_reserva_id;

  -- mesma validacao do rooming do CIO: nome obrigatorio, origem de
  -- transfer valida, data de nascimento obrigatoria pra crianca e
  -- nunca depois do evento comecar
  for v_item in select * from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb))
  loop
    if coalesce(trim(v_item ->> 'nome'), '') = '' then
      raise exception 'Todo ocupante precisa de nome' using errcode = '22023';
    end if;
    perform _exige_origem_transfer(nullif(v_item ->> 'transfer_origem',''));
    v_nasc := nullif(v_item ->> 'data_nascimento','')::date;
    if v_nasc is not null and v_nasc > v_limite then
      raise exception 'Data de nascimento depois do inicio do evento (%): %', v_limite, v_nasc
        using errcode = '22023';
    end if;
    if coalesce(v_item ->> 'tipo','adulto') = 'crianca' and v_nasc is null then
      raise exception 'Informe a data de nascimento das criancas' using errcode = '22023';
    end if;
  end loop;

  delete from ocupantes where reserva_id = p_reserva_id;

  insert into ocupantes (reserva_id, nome, cpf, data_nascimento, tipo,
                         usa_transfer, transfer_origem, email, telefone,
                         categoria_cracha, dificuldade_mobilidade, tem_alergia,
                         alergia_detalhe, precisa_berco, observacoes)
  select
    p_reserva_id,
    trim(x ->> 'nome'),
    nullif(x ->> 'cpf',''),
    nullif(x ->> 'data_nascimento','')::date,
    coalesce(nullif(x ->> 'tipo',''), 'adulto'),
    (x ->> 'usa_transfer')::boolean,
    nullif(x ->> 'transfer_origem',''),
    nullif(x ->> 'email',''),
    nullif(x ->> 'telefone',''),
    'PATROCINADOR',
    coalesce((x ->> 'dificuldade_mobilidade')::boolean, false),
    coalesce((x ->> 'tem_alergia')::boolean, false),
    nullif(x ->> 'alergia_detalhe',''),
    coalesce((x ->> 'precisa_berco')::boolean, false),
    nullif(x ->> 'observacoes','')
  from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb)) x;

  update reservas set
    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),
    transfer_origem = coalesce(p_transfer_origem, transfer_origem),
    -- preenchido = tem gente. Exigir a capacidade cheia prenderia em
    -- rascunho o duplo ocupado por uma pessoa so, que e caso legitimo,
    -- e travaria o fechado_em (logo, a fila da mesa redonda).
    status          = case when v_qtd > 0 then 'completo' else 'rascunho' end
  where id = p_reserva_id;

  perform _recalcular_fechado(v_patro);

  return jsonb_build_object('ok', true, 'ocupantes', v_qtd, 'capacidade', v_cap);
end;
$$;

-- ---------------------------------------------------------------------
-- patro_listar_quartos
-- ---------------------------------------------------------------------
create or replace function patro_listar_quartos(p_patrocinador_id uuid)
returns table (reserva_id uuid, rotulo text, tipo text, origem text,
               capacidade integer, ocupantes integer, usa_transfer boolean,
               transfer_origem text, status text, quarto_numero text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_patrocinador(p_patrocinador_id);
  return query
    select r.id, r.rotulo, r.tipo, r.origem,
           _capacidade_quarto_patrocinador(r.tipo),
           (select count(*)::int from ocupantes o where o.reserva_id = r.id),
           r.usa_transfer, r.transfer_origem, r.status, q.numero
    from reservas r
    left join quartos q on q.id = r.quarto_id
    where r.patrocinador_id = p_patrocinador_id
      and r.status <> 'cancelado'
    order by r.created_at;
end;
$$;

revoke execute on function _capacidade_quarto_patrocinador(text) from public, anon;
grant execute on function _capacidade_quarto_patrocinador(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- autoconferencia: patrocinador fixo por tipo, CIO continua no teto de 4
-- ---------------------------------------------------------------------
do $$
begin
  if _capacidade_quarto_patrocinador('single') <> 1
     or _capacidade_quarto_patrocinador('duplo') <> 2
     or _capacidade_quarto_patrocinador('triplo') <> 3 then
    raise exception 'capacidade do patrocinador por tipo nao bateu com o esperado (single=1, duplo=2, triplo=3)';
  end if;
  if _capacidade_quarto('duplo') <> 4 then
    raise exception 'capacidade do CIO deveria continuar fixa em 4 — nao era pra esta migration mexer nisso';
  end if;
end $$;
