-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- O brinde e da empresa, nao do quarto — e pode custar.
--
-- O QUE ESTAVA ERRADO
--
-- 20260825100000 modelou brinde como uma linha por QUARTO, porque a
-- tela de quarto era onde o patrocinador o declarava. Errado: a empresa
-- manda UM brinde. Ela nao escolhe caneca para o 204 e agenda para o
-- 205 — ela manda 60 canecas. Perguntar de novo a cada quarto e pedir
-- ao patrocinador que repita a mesma resposta oito vezes, e depois
-- conciliar oito respostas que podem divergir.
--
-- O DESTINO, QUE E O QUE CUSTA
--
--   stand    fica na mesa da empresa; quem quer, pega. Sem custo.
--   quarto   a equipe do resort sobe e deixa em cada porta. Tem custo,
--            porque e camareira por porta — cobrado por quarto atendido.
--
-- O preco vem de um item novo, `entrega_brinde_quarto`, configuravel na
-- aba Precos como qualquer outro. Enquanto ninguem preencher, vale zero
-- e nada e cobrado: o padrao nao inventa numero.
--
-- A CONSOLIDACAO
--
-- Brindes por quarto viram um por empresa. Mantem o mais adiantado no
-- rastreio (entregue > recebido > enviado > prometido) e junta as
-- descricoes distintas — descartar o texto que o patrocinador escreveu
-- seria perder informacao que so ele tem.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. DESTINO
-- ---------------------------------------------------------------------
alter table brindes add column if not exists destino text not null default 'stand';

alter table brindes drop constraint if exists brindes_destino_check;
alter table brindes add constraint brindes_destino_check
  check (destino in ('stand','quarto'));

comment on column brindes.destino is
  'stand = fica na mesa da empresa, sem custo. quarto = resort entrega porta a porta, cobrado por quarto.';

-- ---------------------------------------------------------------------
-- 2. UM BRINDE POR EMPRESA
--
-- O indice unico antigo era por reserva. O novo e por patrocinador.
-- ---------------------------------------------------------------------
with ordenado as (
  select b.id, b.patrocinador_id, b.descricao, b.quantidade,
         row_number() over (
           partition by b.patrocinador_id
           order by case b.status when 'entregue' then 1 when 'recebido' then 2
                                  when 'enviado' then 3 when 'prometido' then 4
                                  else 5 end,
                    b.created_at) as n
  from brindes b
),
juntado as (
  select patrocinador_id,
         (array_agg(id order by n))[1] as manter,
         string_agg(distinct nullif(trim(descricao),''), ' + ') as descricoes,
         sum(coalesce(quantidade,0)) as total_qtd
  from ordenado
  group by patrocinador_id
)
update brindes b set
  reserva_id = null,
  descricao  = coalesce(j.descricoes, b.descricao),
  quantidade = nullif(j.total_qtd, 0)
from juntado j
where b.id = j.manter;

delete from brindes b
 using (select patrocinador_id, (array_agg(id order by
          case status when 'entregue' then 1 when 'recebido' then 2
                      when 'enviado' then 3 when 'prometido' then 4 else 5 end,
          created_at))[1] as manter
        from brindes group by patrocinador_id) j
where b.patrocinador_id = j.patrocinador_id and b.id <> j.manter;

drop index if exists brindes_reserva_uk;
create unique index if not exists brindes_patrocinador_uk
  on brindes (patrocinador_id);

-- ---------------------------------------------------------------------
-- 3. A TELA DO QUARTO PARA DE PERGUNTAR SOBRE BRINDE
--
-- Assinatura nova, entao DROP. O portal desta mesma leva ja nao manda
-- os dois parametros.
-- ---------------------------------------------------------------------
drop function if exists patro_salvar_quarto(uuid, jsonb, boolean, text, boolean, text);

CREATE OR REPLACE FUNCTION gestao.patro_salvar_quarto(p_reserva_id uuid, p_ocupantes jsonb, p_usa_transfer boolean DEFAULT NULL::boolean, p_transfer_origem text DEFAULT NULL::text)
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


  perform _recalcular_fechado(v_patro);

  return jsonb_build_object('ok', true, 'ocupantes', v_qtd, 'capacidade', v_cap);
end;
$function$;

-- `patro_listar_quartos` devolvia brinde por quarto; nao existe mais.
drop function if exists patro_listar_quartos(uuid);

create function patro_listar_quartos(p_patrocinador_id uuid)
returns table (reserva_id uuid, rotulo text, tipo text, origem text,
               capacidade integer, ocupantes integer, usa_transfer boolean,
               transfer_origem text, status text, quarto_numero text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_patrocinador(p_patrocinador_id);
  return query
    select r.id, r.rotulo, r.tipo, r.origem,
           _capacidade_quarto(r.tipo),
           (select count(*)::int from ocupantes o where o.reserva_id = r.id),
           r.usa_transfer, r.transfer_origem, r.status, q.numero
    from reservas r
    left join quartos q on q.id = r.quarto_id
    where r.patrocinador_id = p_patrocinador_id
      and r.status <> 'cancelado'
    order by r.created_at;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. O BRINDE DA EMPRESA
-- ---------------------------------------------------------------------
drop function if exists patro_meus_brindes(uuid);

create function patro_meu_brinde(p_patrocinador_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_out jsonb; v_quartos int; v_preco numeric(12,2); v_evento uuid;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;
  select count(*) into v_quartos from reservas r
   where r.patrocinador_id = p_patrocinador_id and r.status <> 'cancelado';
  v_preco := _preco_item(v_evento, 'entrega_brinde_quarto');

  select to_jsonb(b) into v_out from brindes b
   where b.patrocinador_id = p_patrocinador_id;

  -- o custo vai junto para a tela avisar ANTES de salvar: descobrir que
  -- a escolha custa dinheiro depois de confirmada e o tipo de surpresa
  -- que gera ligacao
  return coalesce(v_out, '{}'::jsonb) || jsonb_build_object(
    'quartos', v_quartos,
    'preco_entrega', v_preco,
    'custo_se_quarto', v_quartos * v_preco);
end;
$$;

create or replace function patro_salvar_brinde(
  p_patrocinador_id uuid,
  p_vai_enviar boolean,
  p_descricao text default null,
  p_quantidade int default null,
  p_destino text default 'stand'
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_patrocinador(p_patrocinador_id);

  if p_destino not in ('stand','quarto') then
    raise exception 'Destino invalido: %. Use stand ou quarto', p_destino
      using errcode = '22023';
  end if;
  if coalesce(p_vai_enviar,false) and coalesce(trim(p_descricao),'') = '' then
    raise exception 'Diga o que e o brinde' using errcode = '22023';
  end if;

  insert into brindes (patrocinador_id, vai_enviar, descricao, quantidade, destino)
  values (p_patrocinador_id, coalesce(p_vai_enviar,false),
          nullif(trim(p_descricao),''), p_quantidade, p_destino)
  on conflict (patrocinador_id) do update set
    vai_enviar = excluded.vai_enviar,
    descricao  = excluded.descricao,
    quantidade = excluded.quantidade,
    destino    = excluded.destino,
    updated_at = now();

  perform _recalcular_fatura_patrocinador(p_patrocinador_id);

  return patro_meu_brinde(p_patrocinador_id);
end;
$$;

CREATE OR REPLACE FUNCTION gestao._recalcular_fatura_patrocinador(p_patrocinador_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_evento uuid; v_fatura uuid; v_total numeric(12,2) := 0;
  v_linha record; v_pt numeric(12,2);
  v_travada numeric(12,2);
begin
  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;
  if v_evento is null then return 0; end if;

  -- emitida/paga esta congelada: recalculo automatico para aqui.
  select total into v_travada from faturas
   where patrocinador_id = p_patrocinador_id and status in ('emitida','paga');
  if v_travada is not null then
    return v_travada;
  end if;

  select id into v_fatura from faturas
   where patrocinador_id = p_patrocinador_id and status = 'estimada';

  if v_fatura is null then
    insert into faturas (evento_id, patrocinador_id, status)
    values (v_evento, p_patrocinador_id, 'estimada')
    returning id into v_fatura;
  else
    delete from fatura_itens where fatura_id = v_fatura;
  end if;

  for v_linha in
    select r.tipo, count(*) as qtd
    from reservas r
    where r.patrocinador_id = p_patrocinador_id
      and r.origem = 'extra' and r.status <> 'cancelado'
    group by r.tipo
  loop
    declare v_v numeric(12,2) := _preco_item(v_evento, 'quarto_' || v_linha.tipo);
    begin
      if v_v > 0 then
        insert into fatura_itens (fatura_id, descricao, quantidade, valor_unit)
        values (v_fatura, 'Quarto extra ' || v_linha.tipo, v_linha.qtd, v_v);
        v_total := v_total + v_linha.qtd * v_v;
      end if;
    end;
  end loop;

  for v_linha in
    select _idade_no_evento(v_evento, o.data_nascimento) as idade,
           count(*) as qtd
    from ocupantes o
    join reservas r on r.id = o.reserva_id and r.status <> 'cancelado'
    where r.patrocinador_id = p_patrocinador_id and o.usa_transfer
    group by 1
  loop
    v_pt := _preco_item(v_evento, 'transfer', v_linha.idade);
    if v_pt > 0 then
      insert into fatura_itens (fatura_id, descricao, quantidade, valor_unit)
      values (v_fatura, 'Transfer', v_linha.qtd, v_pt);
      v_total := v_total + v_linha.qtd * v_pt;
    end if;
  end loop;

  -- Entrega no quarto e servico do resort, cobrado por porta: e
  -- camareira subindo com caixa. No stand nao ha custo — o brinde fica
  -- na mesa e quem quer, pega.
  if exists (select 1 from brindes b
              where b.patrocinador_id = p_patrocinador_id
                and b.vai_enviar and b.destino = 'quarto') then
    declare
      v_quartos int;
      v_ve numeric(12,2) := _preco_item(v_evento, 'entrega_brinde_quarto');
    begin
      select count(*) into v_quartos from reservas r
       where r.patrocinador_id = p_patrocinador_id and r.status <> 'cancelado';
      if v_ve > 0 and v_quartos > 0 then
        insert into fatura_itens (fatura_id, descricao, quantidade, valor_unit)
        values (v_fatura, 'Entrega de brinde no quarto', v_quartos, v_ve);
        v_total := v_total + v_quartos * v_ve;
      end if;
    end;
  end if;

  update faturas set total = v_total where id = v_fatura;

  if v_total = 0 then
    delete from fatura_itens where fatura_id = v_fatura;
    delete from faturas where id = v_fatura;
  end if;

  return v_total;
end;
$function$;

-- ---------------------------------------------------------------------
-- 5. PERMISSAO
-- ---------------------------------------------------------------------
revoke execute on function patro_salvar_quarto(uuid, jsonb, boolean, text) from public, anon;
revoke execute on function patro_listar_quartos(uuid) from public, anon;
revoke execute on function patro_meu_brinde(uuid) from public, anon;
revoke execute on function patro_salvar_brinde(uuid, boolean, text, int, text) from public, anon;
grant execute on function patro_salvar_quarto(uuid, jsonb, boolean, text) to authenticated, service_role;
grant execute on function patro_listar_quartos(uuid) to authenticated, service_role;
grant execute on function patro_meu_brinde(uuid) to authenticated, service_role;
grant execute on function patro_salvar_brinde(uuid, boolean, text, int, text) to authenticated, service_role;
