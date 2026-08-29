-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Data de nascimento valida contra a data do EVENTO, nao so contra hoje.
--
-- O BURACO
--
-- part_salvar_rooming so recusava data de nascimento no futuro em
-- relacao a HOJE (current_date). Mas a idade que importa pro sistema
-- e a idade NO EVENTO (README §6: "a idade considerada e a do inicio
-- do evento, nao a de hoje"), que pode ser meses ou anos a frente.
-- Uma data de nascimento entre hoje e o inicio do evento passava pela
-- checagem antiga sem erro, e dava idade NEGATIVA no calculo — achado
-- real do QA de usabilidade (Cowork), confirmado no codigo.
--
-- Achado no mesmo teste: quando o evento ainda nao tem data_inicio
-- marcada (rascunho), nao ha o que comparar — mantem so a checagem
-- contra hoje, igual antes.
-- =====================================================================

set search_path = gestao, public;

CREATE OR REPLACE FUNCTION "gestao"."part_salvar_rooming"(
  "p_evento_slug" "text", "p_acompanhantes" "jsonb",
  "p_usa_transfer" boolean DEFAULT NULL::boolean,
  "p_transfer_origem" "text" DEFAULT NULL::"text"
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
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

  -- +1 pelo titular, que nao vem no payload mas ocupa cama
  v_qtd := jsonb_array_length(coalesce(p_acompanhantes,'[]'::jsonb)) + 1;
  if v_qtd > _capacidade_quarto() then
    raise exception
      'O quarto comporta % pessoa(s), incluindo voce; foram informadas %. Acima disso e quarto adicional.',
      _capacidade_quarto(), v_qtd using errcode = '22023';
  end if;

  -- a idade que conta e a do inicio do evento (README §6); sem essa
  -- data (evento em rascunho) so da pra recusar o que ja e impossivel
  -- hoje
  select coalesce(e.data_inicio, current_date) into v_limite
  from eventos e where e.slug = p_evento_slug;

  -- valida antes de apagar qualquer coisa
  for v_item in select * from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb))
  loop
    if coalesce(trim(v_item ->> 'nome'),'') = '' then
      raise exception 'Todo acompanhante precisa de nome' using errcode = '22023';
    end if;
    v_nasc := nullif(v_item ->> 'data_nascimento','')::date;
    if v_nasc is not null and v_nasc > v_limite then
      raise exception 'Data de nascimento depois do início do evento (%): %', v_limite, v_nasc
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
$$;
