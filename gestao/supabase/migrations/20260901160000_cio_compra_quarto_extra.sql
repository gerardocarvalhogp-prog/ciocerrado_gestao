-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- CIO pode comprar quarto adicional — só patrocinador tinha esse
-- caminho (patro_comprar_quarto). O rooming do CIO já avisa "acima
-- disso é quarto adicional" quando estoura a capacidade, mas não
-- oferecia a opção — só dizia o limite.
--
-- MESMO PADRAO DO PATROCINADOR
--
-- part_comprar_quarto / part_cancelar_quarto_extra espelham
-- patro_comprar_quarto / patro_cancelar_quarto_extra: reserva nova
-- (origem 'extra'), quarto do tipo escolhido, o primeiro livre com
-- lock (for update skip locked evita dois CIOs pegando o mesmo
-- quarto). part_listar_meus_quartos mostra a reserva principal e
-- qualquer extra junto.
--
-- A FATURA NAO COBRAVA QUARTO EXTRA DE CIO
--
-- _recalcular_fatura_participante tinha os dois loops de sempre
-- (acompanhante/crianca, transfer) mas nenhum pra quarto extra —
-- diferente de _recalcular_fatura_patrocinador, que ja cobrava. Sem
-- isso, comprar um quarto a mais nao aparecia na conta do CIO.
-- =====================================================================

set search_path = gestao, public;

create or replace function part_comprar_quarto(p_evento_slug text, p_tipo text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_part    uuid;
  v_evento  uuid;
  v_quarto  uuid;
  v_reserva uuid;
  v_seq     int;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;

  if p_tipo not in ('single','duplo','triplo') then
    raise exception 'Tipo de quarto invalido: %', p_tipo using errcode = '22023';
  end if;

  select evento_id into v_evento from participantes where id = v_part;

  select q.id into v_quarto
  from quartos q
  where q.evento_id = v_evento
    and q.tipo = p_tipo
    and q.status = 'disponivel'
    and not exists (select 1 from reservas r
                    where r.quarto_id = q.id and r.status <> 'cancelado')
  order by q.numero nulls last
  limit 1
  for update of q skip locked;

  if v_quarto is null then
    return jsonb_build_object('ok', false, 'motivo', 'sem_disponibilidade');
  end if;

  update quartos set status = 'reservado' where id = v_quarto;

  select count(*) + 1 into v_seq from reservas
   where participante_id = v_part and origem = 'extra' and status <> 'cancelado';

  insert into reservas (evento_id, quarto_id, participante_id, rotulo,
                        tipo, origem, status)
  values (v_evento, v_quarto, v_part,
          'Quarto extra ' || v_seq, p_tipo, 'extra', 'rascunho')
  returning id into v_reserva;

  perform _recalcular_fatura_participante(v_part);

  return jsonb_build_object('ok', true, 'reserva_id', v_reserva);
end;
$$;

create or replace function part_cancelar_quarto_extra(p_reserva_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_part uuid; v_quarto uuid; v_origem text;
begin
  select participante_id, quarto_id, origem
    into v_part, v_quarto, v_origem
  from reservas where id = p_reserva_id;

  perform _exige_participante(v_part);

  if v_origem <> 'extra' then
    raise exception 'Só quarto extra pode ser cancelado pelo portal'
      using errcode = '42501';
  end if;

  update reservas set status = 'cancelado' where id = p_reserva_id;
  if v_quarto is not null then
    update quartos set status = 'disponivel' where id = v_quarto;
  end if;

  perform _recalcular_fatura_participante(v_part);

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function part_listar_meus_quartos(p_evento_slug text)
returns table (reserva_id uuid, rotulo text, tipo text, origem text, status text, quarto_numero text)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_part uuid;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;

  return query
    select r.id, r.rotulo, r.tipo, r.origem, r.status, q.numero
    from reservas r
    left join quartos q on q.id = r.quarto_id
    where r.participante_id = v_part and r.status <> 'cancelado'
    order by (r.origem = 'extra'), r.created_at;
end;
$$;

-- ---------------------------------------------------------------------
-- Fatura do participante ganha a cobranca de quarto extra que ja
-- existia pra patrocinador — so o loop novo, resto identico
-- ---------------------------------------------------------------------
create or replace function gestao._recalcular_fatura_participante(p_participante_id uuid)
 returns numeric
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare
  v_evento uuid; v_res uuid; v_fatura uuid;
  v_total numeric(12,2) := 0; v_linha record;
  v_pt numeric(12,2); v_travada numeric(12,2);
begin
  perform _exige_participante(p_participante_id);

  select evento_id into v_evento from participantes where id = p_participante_id;
  if v_evento is null then return 0; end if;

  -- v_res pode ficar nulo (CIO comprou quarto extra antes de confirmar
  -- o proprio rooming — caminho novo, antes impossivel). Segue mesmo
  -- assim: os dois primeiros loops (que leem ocupante da reserva
  -- principal) ficam vazios, mas quarto extra nao depende de v_res.
  select id into v_res from reservas
   where participante_id = p_participante_id and status <> 'cancelado' and origem <> 'extra';

  select total into v_travada from faturas
   where participante_id = p_participante_id and status in ('emitida','paga');
  if v_travada is not null then
    return v_travada;
  end if;

  select id into v_fatura from faturas
   where participante_id = p_participante_id and status = 'estimada';

  if v_fatura is null then
    insert into faturas (evento_id, participante_id, status)
    values (v_evento, p_participante_id, 'estimada')
    returning id into v_fatura;
  else
    delete from fatura_itens where fatura_id = v_fatura;
  end if;

  for v_linha in
    with base as (
      select o.id,
             _item_do_ocupante(o.tipo) as item,
             _idade_no_evento(v_evento, o.data_nascimento) as idade
      from ocupantes o
      where o.reserva_id = v_res and o.tipo <> 'titular'
    ),
    marcado as (
      select b.*,
             b.item = 'acompanhante_adulto'
               and row_number() over (
                     partition by b.item
                     order by _preco_item(v_evento, b.item, b.idade) desc, b.id
                   ) <= _cortesia_acompanhante() as cortesia
      from base b
    )
    select item, idade, cortesia, count(*) as qtd
    from marcado
    group by 1, 2, 3
  loop
    declare
      v_valor numeric(12,2) := _preco_item(v_evento, v_linha.item, v_linha.idade);
      v_desc text;
    begin
      v_desc := case when v_linha.item = 'crianca' then 'Criança' else 'Familiar adulto' end
              || case when v_linha.idade is not null
                      then ' · ' || v_linha.idade || ' anos' else '' end;

      if v_linha.cortesia then
        insert into fatura_itens (fatura_id, reserva_id, descricao,
                                  quantidade, valor_unit)
        values (v_fatura, v_res, v_desc || ' · cortesia', v_linha.qtd, 0);
      elsif v_valor > 0 then
        insert into fatura_itens (fatura_id, reserva_id, descricao,
                                  quantidade, valor_unit)
        values (v_fatura, v_res, v_desc, v_linha.qtd, v_valor);
        v_total := v_total + v_linha.qtd * v_valor;
      end if;
    end;
  end loop;

  for v_linha in
    select _idade_no_evento(v_evento, o.data_nascimento) as idade,
           count(*) as qtd
    from ocupantes o
    where o.reserva_id = v_res and o.usa_transfer
    group by 1
  loop
    v_pt := _preco_item(v_evento, 'transfer', v_linha.idade);
    if v_pt > 0 then
      insert into fatura_itens (fatura_id, reserva_id, descricao,
                                quantidade, valor_unit)
      values (v_fatura, v_res,
              'Transfer' || case when v_linha.idade is not null
                                 then ' · ' || v_linha.idade || ' anos' else '' end,
              v_linha.qtd, v_pt);
      v_total := v_total + v_linha.qtd * v_pt;
    end if;
  end loop;

  -- quarto(s) extra — mesma logica de _recalcular_fatura_patrocinador
  for v_linha in
    select r.tipo, count(*) as qtd
    from reservas r
    where r.participante_id = p_participante_id
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

  update faturas set total = v_total where id = v_fatura;
  return v_total;
end;
$function$;

revoke execute on function part_comprar_quarto(text, text) from public, anon;
revoke execute on function part_cancelar_quarto_extra(uuid) from public, anon;
revoke execute on function part_listar_meus_quartos(text) from public, anon;
grant execute on function part_comprar_quarto(text, text) to authenticated, service_role;
grant execute on function part_cancelar_quarto_extra(uuid) to authenticated, service_role;
grant execute on function part_listar_meus_quartos(text) to authenticated, service_role;
