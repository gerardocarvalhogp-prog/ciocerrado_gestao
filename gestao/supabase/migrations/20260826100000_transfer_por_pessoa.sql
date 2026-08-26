-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Transfer e por pessoa, inclusive a origem.
--
-- O QUE ESTAVA ERRADO
--
-- A COBRANCA ja era por pessoa: a fatura conta `ocupantes.usa_transfer`.
-- O que era por quarto e a ORIGEM — `reservas.transfer_origem`, um campo
-- so para o quarto inteiro. Duas pessoas do mesmo quarto podendo vir de
-- cidades diferentes e o caso normal, nao a excecao: marido saindo de
-- Goiania e esposa de Brasilia cabem no mesmo quarto e em onibus
-- diferentes.
--
-- Com um campo por quarto, a organizacao monta a lista do onibus errada
-- e alguem fica na rodoviaria.
--
-- A VALIDACAO QUE TINHA SUMIDO
--
-- A linhagem antiga recusava origem fora de GYN/BSB
-- (`migrations-antigas/20260824100400`, linha 235). A implementacao que
-- virou baseline nao tinha essa checagem: hoje o banco aceita
-- `transfer_origem = 'qualquer coisa'` e ninguem descobre ate montar o
-- onibus. Volta aqui, num helper so — o sistema e multievento e essas
-- siglas mudam a cada edicao.
--
-- `reservas.transfer_origem` continua sendo gravado, porque relatorio e
-- tela ainda leem dele. A verdade passa a ser a do ocupante.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. AS ORIGENS, NUM LUGAR SO
-- ---------------------------------------------------------------------
create or replace function _origens_transfer()
returns text[] language sql immutable
set search_path = gestao, public as $$
  -- Um dia isto vira tabela por evento. Enquanto for uma lista curta e
  -- igual para todos, funcao resolve e deixa obvio onde mexer.
  select array['GYN','BSB'];
$$;

create or replace function _exige_origem_transfer(p_origem text)
returns void language plpgsql immutable
set search_path = gestao, public as $$
begin
  if p_origem is null or p_origem = '' then return; end if;
  if not (p_origem = any (_origens_transfer())) then
    raise exception 'Origem de transfer invalida: %. Use uma de: %',
      p_origem, array_to_string(_origens_transfer(), ', ')
      using errcode = '22023';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. A COLUNA, E O QUE JA EXISTE
--
-- O backfill copia a origem do quarto para quem usa transfer. Sem isso,
-- quem ja preencheu o rooming perderia a origem na primeira leitura da
-- tela nova.
-- ---------------------------------------------------------------------
alter table ocupantes add column if not exists transfer_origem text;

comment on column ocupantes.transfer_origem is
  'De onde esta pessoa sai. Por pessoa, nao por quarto: o mesmo quarto pode ter gente de cidades diferentes.';

update ocupantes o
   set transfer_origem = r.transfer_origem
  from reservas r
 where r.id = o.reserva_id
   and o.usa_transfer
   and o.transfer_origem is null
   and r.transfer_origem is not null;

-- ---------------------------------------------------------------------
-- 3. GRAVACAO
--
-- Texto exato do banco com remendo pontual (ver a nota de metodo em
-- 20260826090000).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gestao.part_salvar_rooming(p_evento_slug text, p_acompanhantes jsonb, p_usa_transfer boolean DEFAULT NULL::boolean, p_transfer_origem text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_part   uuid;
  v_res    uuid;
  v_status jsonb;
  v_prazo  date;
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

  -- +1 pelo titular, que nao vem no payload mas ocupa cama
  v_qtd := jsonb_array_length(coalesce(p_acompanhantes,'[]'::jsonb)) + 1;
  if v_qtd > _capacidade_quarto() then
    raise exception
      'O quarto comporta % pessoa(s), incluindo voce; foram informadas %. Acima disso e quarto adicional.',
      _capacidade_quarto(), v_qtd using errcode = '22023';
  end if;
  -- valida antes de apagar qualquer coisa
  for v_item in select * from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb))
  loop
    if coalesce(trim(v_item ->> 'nome'),'') = '' then
      raise exception 'Todo acompanhante precisa de nome' using errcode = '22023';
    end if;
    v_nasc := nullif(v_item ->> 'data_nascimento','')::date;
    if v_nasc is not null and v_nasc > current_date then
      raise exception 'Data de nascimento no futuro: %', v_nasc
        using errcode = '22023';
    end if;
    perform _exige_origem_transfer(nullif(v_item ->> 'transfer_origem',''));
    -- crianca precisa de data de nascimento: e o que define a cobranca
    -- e a regra de cracha (menor de 21 fica sem)
    if coalesce(v_item ->> 'tipo','adulto') = 'crianca' and v_nasc is null then
      raise exception 'Informe a data de nascimento das criancas'
        using errcode = '22023';
    end if;
  end loop;

  v_res := _garantir_reserva(v_part);

  -- preserva o titular; troca so os acompanhantes
  delete from ocupantes where reserva_id = v_res and tipo <> 'titular';

  insert into ocupantes (reserva_id, nome, cpf, data_nascimento, tipo,
                         usa_transfer, transfer_origem, categoria_cracha)
  select v_res,
         trim(x ->> 'nome'),
         nullif(x ->> 'cpf',''),
         nullif(x ->> 'data_nascimento','')::date,
         coalesce(nullif(x ->> 'tipo',''), 'adulto'),
         (x ->> 'usa_transfer')::boolean,
         nullif(x ->> 'transfer_origem',''),
         'ACOMPANHANTE'
  from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb)) x;

  -- titular entra sozinho se ainda nao existe
  insert into ocupantes (reserva_id, nome, tipo, categoria_cracha, email)
  select v_res, g.nome, 'titular', 'PROTAGONISTA', g.email
  from participantes pa join gestores g on g.id = pa.gestor_id
  where pa.id = v_part
    and not exists (select 1 from ocupantes o
                    where o.reserva_id = v_res and o.tipo = 'titular');

  -- O transfer do titular vem no campo do formulario, nao na lista de
  -- acompanhantes. Sem gravar aqui, a fatura contaria um transfer a
  -- menos do que a previa mostrou na tela.
  update ocupantes set
    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),
    transfer_origem = coalesce(p_transfer_origem, transfer_origem)
   where reserva_id = v_res and tipo = 'titular';

  update reservas set
    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),
    transfer_origem = coalesce(p_transfer_origem, transfer_origem),
    status          = 'completo'
  where id = v_res;

  insert into notificacoes (evento_id, destinatario, tipo, assunto)
  select r.evento_id, g.email, 'rooming_ok', 'Dados de hospedagem confirmados'
  from reservas r
  join participantes pa on pa.id = r.participante_id
  join gestores g on g.id = pa.gestor_id
  where r.id = v_res;

  return part_calcular_fatura(p_evento_slug);
end;
$function$;

CREATE OR REPLACE FUNCTION gestao.patro_salvar_quarto(p_reserva_id uuid, p_ocupantes jsonb, p_usa_transfer boolean DEFAULT NULL::boolean, p_transfer_origem text DEFAULT NULL::text, p_brinde_enviar boolean DEFAULT NULL::boolean, p_brinde_descricao text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_patro uuid;
  v_tipo  text;
  v_cap   int;
  v_qtd   int;
  v_item  jsonb;
begin
  select patrocinador_id, tipo into v_patro, v_tipo
  from reservas where id = p_reserva_id and status <> 'cancelado';

  if v_patro is null then
    raise exception 'Reserva nao encontrada' using errcode = 'P0002';
  end if;
  perform _exige_patrocinador(v_patro);

  -- o tipo virou rotulo de preco: quem manda na lotacao e o teto do
  -- quarto, igual para todos
  v_cap := _capacidade_quarto(v_tipo);
  v_qtd := jsonb_array_length(coalesce(p_ocupantes, '[]'::jsonb));

  if v_qtd > v_cap then
    raise exception 'O quarto comporta % pessoa(s); voce enviou %. Acima disso e quarto adicional.',
      v_cap, v_qtd using errcode = '22023';
  end if;

  perform _exige_origem_transfer(p_transfer_origem);

  -- nome vazio nao entra: e o erro mais comum no preenchimento
  for v_item in select * from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb))
  loop
    if coalesce(trim(v_item ->> 'nome'), '') = '' then
      raise exception 'Todo ocupante precisa de nome' using errcode = '22023';
    end if;
    perform _exige_origem_transfer(nullif(v_item ->> 'transfer_origem',''));
  end loop;

  delete from ocupantes where reserva_id = p_reserva_id;

  insert into ocupantes (reserva_id, nome, cpf, data_nascimento, tipo,
                         usa_transfer, transfer_origem, email, telefone,
                         categoria_cracha)
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
    'PATROCINADOR'
  from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb)) x;

  update reservas set
    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),
    transfer_origem = coalesce(p_transfer_origem, transfer_origem),
    -- preenchido = tem gente. Exigir a capacidade cheia prenderia em
    -- rascunho o duplo ocupado por uma pessoa so, que e caso legitimo,
    -- e travaria o fechado_em (logo, a fila da mesa redonda).
    status          = case when v_qtd > 0 then 'completo' else 'rascunho' end
  where id = p_reserva_id;

  if p_brinde_enviar is not null or p_brinde_descricao is not null then
    insert into brindes (patrocinador_id, reserva_id, vai_enviar, descricao)
    values (v_patro, p_reserva_id, coalesce(p_brinde_enviar,false), p_brinde_descricao)
    on conflict do nothing;

    update brindes set
      vai_enviar = coalesce(p_brinde_enviar, vai_enviar),
      descricao  = coalesce(p_brinde_descricao, descricao)
    where reserva_id = p_reserva_id;
  end if;

  perform _recalcular_fechado(v_patro);

  return jsonb_build_object('ok', true, 'ocupantes', v_qtd, 'capacidade', v_cap);
end;
$function$;

-- ---------------------------------------------------------------------
-- 4. LEITURA: as telas precisam receber a origem de cada pessoa
-- ---------------------------------------------------------------------
drop function if exists part_listar_rooming(text);
CREATE OR REPLACE FUNCTION gestao.part_listar_rooming(p_evento_slug text)
 RETURNS TABLE(id uuid, nome text, cpf text, data_nascimento date, tipo text, usa_transfer boolean, transfer_origem text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$

declare v_part uuid;

begin

  v_part := _meu_participante(p_evento_slug);

  if v_part is null then return; end if;



  return query

    select o.id, o.nome, o.cpf, o.data_nascimento, o.tipo, o.usa_transfer,
           o.transfer_origem

    from ocupantes o

    join reservas r on r.id = o.reserva_id

    where r.participante_id = v_part and r.status <> 'cancelado'

    order by (o.tipo = 'titular') desc, o.created_at;

end;

$function$;

drop function if exists patro_listar_ocupantes(uuid);
CREATE OR REPLACE FUNCTION gestao.patro_listar_ocupantes(p_reserva_id uuid)
 RETURNS TABLE(ocupante_id uuid, nome text, cpf text, data_nascimento date, tipo text, usa_transfer boolean, transfer_origem text, email text, telefone text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$

declare v_patro uuid;

begin

  select r.patrocinador_id into v_patro

  from reservas r where r.id = p_reserva_id;



  perform _exige_patrocinador(v_patro);



  return query

    select o.id, o.nome, o.cpf, o.data_nascimento,

           o.tipo, o.usa_transfer, o.transfer_origem, o.email, o.telefone

    from ocupantes o where o.reserva_id = p_reserva_id

    order by o.created_at;

end;

$function$;

-- ---------------------------------------------------------------------
-- 5. PERMISSAO
-- ---------------------------------------------------------------------
revoke execute on function _origens_transfer() from public, anon;
revoke execute on function _exige_origem_transfer(text) from public, anon;
revoke execute on function part_listar_rooming(text) from public, anon;
revoke execute on function patro_listar_ocupantes(uuid) from public, anon;
grant execute on function _origens_transfer() to authenticated, service_role;
grant execute on function _exige_origem_transfer(text) to authenticated, service_role;
grant execute on function part_listar_rooming(text) to authenticated, service_role;
grant execute on function patro_listar_ocupantes(uuid) to authenticated, service_role;
