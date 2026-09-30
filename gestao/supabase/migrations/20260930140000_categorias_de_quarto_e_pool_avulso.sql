-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Volta a existir um jeito de reservar numero de quarto por publico —
-- pedido do organizador em 30/09/2026, ciente de que um mecanismo
-- parecido (quartos.publico_alvo: cio/organizacao/cotas) tinha sido
-- removido em 09/09/2026 por risco de CIO e patrocinador disputarem,
-- sem supervisao, um numero que a organizacao ainda nao tinha
-- terminado de reservar pra cota de um patrocinador grande.
--
-- DESENHO NOVO, MESMO RISCO EVITADO
--
-- quartos.finalidade (NOT NULL, 5 valores: cio / patrocinador /
-- organizacao / staff / avulso) substitui o publico_alvo antigo — sem
-- NULL ambiguo, todo quarto tem uma finalidade explicita desde que
-- existe (default 'avulso', o pool flexivel).
--
-- admin_alocar_quarto (staff aloca um a um, supervisionado — nunca foi
-- o problema) passa a recusar reserva de categoria incompativel com a
-- finalidade do quarto, "avulso" sempre aceita qualquer categoria.
--
-- patro_comprar_quarto (automatico, sem supervisao) so pesca de
-- finalidade='avulso' agora — nunca mais dos pools cio/patrocinador/
-- organizacao/staff, que ficam reservados pra alocacao manual.
--
-- part_comprar_quarto/part_cancelar_quarto_extra/part_listar_meus_quartos
-- (removidas em 09/09 junto com publico_alvo) voltam, com a MESMA
-- regra: so pescam do pool avulso. Ganham tambem
-- part_salvar_ocupantes_extra, que nao existia antes — o CIO podia
-- comprar e cancelar quarto extra mas nunca teve como preencher quem
-- ia dentro (rooming.html nunca teve essa tela).
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. A COLUNA
-- ---------------------------------------------------------------------
alter table quartos add column if not exists finalidade text;
update quartos set finalidade = 'avulso' where finalidade is null;
alter table quartos alter column finalidade set not null;
alter table quartos alter column finalidade set default 'avulso';
alter table quartos drop constraint if exists quartos_finalidade_check;
alter table quartos add constraint quartos_finalidade_check
  check (finalidade in ('cio','patrocinador','organizacao','staff','avulso'));
comment on column quartos.finalidade is
  'Pra quem esse numero e reservado, antes mesmo de qualquer alocacao. "avulso" e o pool flexivel: aceita qualquer categoria, e o que patro_comprar_quarto/part_comprar_quarto pescam.';

-- ---------------------------------------------------------------------
-- 2. DEFINIR A FINALIDADE — um quarto, ou uma faixa inteira
-- ---------------------------------------------------------------------
create or replace function admin_definir_finalidade_quarto(p_id uuid, p_finalidade text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_numero text; v_origem_ocupante text;
  v_patro_ocupante uuid; v_part_ocupante uuid; v_achou_reserva boolean;
begin
  perform _exige_admin();

  if p_finalidade not in ('cio','patrocinador','organizacao','staff','avulso') then
    raise exception 'Finalidade invalida: %', p_finalidade using errcode = '22023';
  end if;

  -- se ja tem gente reservada ali, a nova finalidade precisa continuar
  -- aceitando essa reserva — senao o quarto fica marcado pra um
  -- publico que nao e o de quem esta dentro. Equipe aceita tanto
  -- organizacao quanto staff, entao checa as duas em vez de exigir uma
  -- categoria exata (era o que a versao anterior desta funcao pulava
  -- por engano, sem checar nada pra quarto de equipe).
  select true, r.origem, r.patrocinador_id, r.participante_id
    into v_achou_reserva, v_origem_ocupante, v_patro_ocupante, v_part_ocupante
  from reservas r where r.quarto_id = p_id and r.status <> 'cancelado';

  if v_achou_reserva and p_finalidade <> 'avulso' then
    if v_origem_ocupante = 'equipe' then
      if p_finalidade not in ('organizacao','staff') then
        raise exception 'Este quarto ja esta ocupado por uma reserva de equipe; libere a atribuicao antes de trocar a finalidade'
          using errcode = '55000';
      end if;
    elsif v_patro_ocupante is not null and p_finalidade <> 'patrocinador' then
      raise exception 'Este quarto ja esta ocupado por uma reserva de patrocinador; libere a atribuicao antes de trocar a finalidade'
        using errcode = '55000';
    elsif v_part_ocupante is not null and p_finalidade <> 'cio' then
      raise exception 'Este quarto ja esta ocupado por uma reserva de CIO; libere a atribuicao antes de trocar a finalidade'
        using errcode = '55000';
    end if;
  end if;

  update quartos set finalidade = p_finalidade where id = p_id
  returning numero into v_numero;

  if not found then
    raise exception 'Quarto nao encontrado' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true, 'numero', v_numero, 'finalidade', p_finalidade);
end;
$$;

create or replace function admin_definir_finalidade_faixa(p_evento_slug text, p_de text, p_ate text, p_finalidade text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_n int; v_de int; v_ate int;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;
  if p_finalidade not in ('cio','patrocinador','organizacao','staff','avulso') then
    raise exception 'Finalidade invalida: %', p_finalidade using errcode = '22023';
  end if;

  v_de  := nullif(regexp_replace(coalesce(p_de,''),  '[^0-9]', '', 'g'), '')::int;
  v_ate := nullif(regexp_replace(coalesce(p_ate,''), '[^0-9]', '', 'g'), '')::int;

  if v_de is null or v_ate is null or v_ate < v_de then
    raise exception 'Faixa invalida: de % ate %', p_de, p_ate using errcode = '22023';
  end if;

  -- pula quarto ocupado por reserva incompativel, em vez de falhar a
  -- faixa inteira por causa de um numero: o resto da faixa continua
  -- valendo, e o admin ve quantos ficaram de fora
  update quartos q set finalidade = p_finalidade
  where q.evento_id = v_evento
    and q.numero ~ '^[0-9]+$'
    and q.numero::int between v_de and v_ate
    and q.finalidade is distinct from p_finalidade
    and not exists (
      select 1 from reservas r
      where r.quarto_id = q.id and r.status <> 'cancelado'
        and p_finalidade <> 'avulso'
        and (
          (r.origem = 'equipe' and p_finalidade not in ('organizacao','staff'))
          or (r.patrocinador_id is not null and p_finalidade <> 'patrocinador')
          or (r.participante_id is not null and p_finalidade <> 'cio')
        )
    );

  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'alterados', v_n, 'de', v_de, 'ate', v_ate, 'finalidade', p_finalidade);
end;
$$;

revoke execute on function admin_definir_finalidade_quarto(uuid,text) from public, anon;
revoke execute on function admin_definir_finalidade_faixa(text,text,text,text) from public, anon;
grant execute on function admin_definir_finalidade_quarto(uuid,text) to authenticated, service_role;
grant execute on function admin_definir_finalidade_faixa(text,text,text,text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. QUEM VE O QUARTO PRECISA SABER PRA QUEM ELE E RESERVADO
--    (finalidade e' agora o campo de verdade, guardado — nao mais
--    derivado so do ocupante atual como na migration 20260930130000)
-- ---------------------------------------------------------------------
drop function if exists admin_listar_quartos_individual(text, text);

create function admin_listar_quartos_individual(p_evento_slug text, p_busca text DEFAULT NULL::text)
returns table (
  id uuid, numero text, tipo text, capacidade integer, status text,
  bloco text, andar text, corredor text, categoria text, finalidade text,
  reserva_id uuid, ocupado_por text
)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_termo text;
begin
  perform _exige_staff();
  v_termo := nullif(trim(coalesce(p_busca,'')), '');

  return query
    select q.id, q.numero, q.tipo, q.capacidade, q.status,
           q.bloco, q.andar, q.corredor, q.categoria, q.finalidade,
           r.id,
           coalesce(r.ocupado_por, p.empresa, g.empresa, r.rotulo)
    from quartos q
    join eventos e on e.id = q.evento_id and e.slug = p_evento_slug
    left join reservas r on r.quarto_id = q.id and r.status <> 'cancelado'
    left join patrocinadores p on p.id = r.patrocinador_id
    left join participantes pa on pa.id = r.participante_id
    left join gestores g on g.id = pa.gestor_id
    where v_termo is null
       or q.numero ilike '%'||v_termo||'%'
       or coalesce(q.bloco,'') ilike '%'||v_termo||'%'
    order by
      nullif(regexp_replace(coalesce(q.numero,''),'[^0-9]','','g'),'')::int nulls last,
      q.numero;
end;
$$;

revoke execute on function admin_listar_quartos_individual(text, text) from public, anon;
grant execute on function admin_listar_quartos_individual(text, text) to authenticated, service_role;

-- admin_quartos_livres alimenta o seletor de "Separar quartos" — devolve
-- a finalidade de cada quarto livre pra tela filtrar pela categoria da
-- reserva que esta sendo alocada
drop function if exists admin_quartos_livres(text);

create function admin_quartos_livres(p_evento_slug text)
returns table(id uuid, numero text, tipo text, capacidade integer, finalidade text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select q.id, q.numero, q.tipo, q.capacidade, q.finalidade
    from quartos q
    join eventos e on e.id = q.evento_id and e.slug = p_evento_slug
    where q.status <> 'bloqueado'
      and not exists (select 1 from reservas r
                      where r.quarto_id = q.id and r.status <> 'cancelado')
    order by q.numero nulls last;
end;
$$;

revoke execute on function admin_quartos_livres(text) from public, anon;
grant execute on function admin_quartos_livres(text) to authenticated, service_role;

-- admin_listar_alocacao ganha a categoria da reserva (equipe->equipe,
-- patrocinador->patrocinador, resto->cio), pra tela so oferecer no
-- seletor os quartos compativeis
drop function if exists admin_listar_alocacao(text, boolean);

create function admin_listar_alocacao(p_evento_slug text, p_apenas_sem_quarto boolean DEFAULT false)
returns table(ocupante_id uuid, reserva_id uuid, nome text, empresa text, tipo text,
              quarto_id uuid, quarto_numero text, quarto_tipo text, categoria_reserva text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select o.id, r.id, o.nome,
           coalesce(r.ocupado_por, p.empresa, g.empresa, r.rotulo),
           o.tipo, q.id, q.numero, r.tipo,
           case
             when r.origem = 'equipe' then 'equipe'
             when r.patrocinador_id is not null then 'patrocinador'
             else 'cio'
           end
    from ocupantes o
    join reservas r on r.id = o.reserva_id and r.status <> 'cancelado'
    join eventos  e on e.id = r.evento_id and e.slug = p_evento_slug
    left join quartos q on q.id = r.quarto_id
    left join patrocinadores p on p.id = r.patrocinador_id
    left join participantes pa on pa.id = r.participante_id
    left join gestores g on g.id = pa.gestor_id
    where (not p_apenas_sem_quarto or r.quarto_id is null)
    order by coalesce(r.ocupado_por, p.empresa, g.empresa, r.rotulo), o.nome;
end;
$$;

revoke execute on function admin_listar_alocacao(text,boolean) from public, anon;
grant execute on function admin_listar_alocacao(text,boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. O BLOQUEIO DE VERDADE: quem tenta alocar numero incompativel e recusado
-- ---------------------------------------------------------------------
create or replace function admin_alocar_quarto(p_reserva_id uuid, p_quarto_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_anterior uuid; v_ocupado uuid; v_cap int; v_qtd int;
  v_finalidade_quarto text; v_categoria_reserva text; v_origem text;
  v_patro uuid; v_part uuid;
begin
  perform _exige_staff_da_reserva(p_reserva_id);

  select quarto_id, origem, patrocinador_id, participante_id
    into v_anterior, v_origem, v_patro, v_part
  from reservas where id = p_reserva_id;
  if not found then
    raise exception 'Reserva nao encontrada' using errcode = 'P0002';
  end if;

  if p_quarto_id is null then
    update reservas set quarto_id = null where id = p_reserva_id;
    update quartos set status = 'disponivel' where id = v_anterior;
    return jsonb_build_object('ok', true, 'liberado', true);
  end if;

  select q.capacidade, q.finalidade into v_cap, v_finalidade_quarto
  from quartos q where q.id = p_quarto_id for update;

  if v_finalidade_quarto <> 'avulso' then
    v_categoria_reserva := case
      when v_origem = 'equipe' then 'equipe'
      when v_patro is not null then 'patrocinador'
      else 'cio'
    end;

    if not (
      (v_categoria_reserva = 'equipe' and v_finalidade_quarto in ('organizacao','staff'))
      or v_categoria_reserva = v_finalidade_quarto
    ) then
      return jsonb_build_object('ok', false, 'motivo', 'finalidade_incompativel',
                                'finalidade_quarto', v_finalidade_quarto, 'categoria_reserva', v_categoria_reserva);
    end if;
  end if;

  select r.id into v_ocupado from reservas r
   where r.quarto_id = p_quarto_id and r.status <> 'cancelado'
     and r.id <> p_reserva_id
   limit 1;

  if v_ocupado is not null then
    return jsonb_build_object('ok', false, 'motivo', 'quarto_ocupado');
  end if;

  select count(*) into v_qtd from ocupantes where reserva_id = p_reserva_id;

  if v_qtd > v_cap then
    return jsonb_build_object('ok', false, 'motivo', 'capacidade',
      'ocupantes', v_qtd, 'capacidade', v_cap);
  end if;

  update reservas set quarto_id = p_quarto_id where id = p_reserva_id;
  update quartos set status = 'reservado' where id = p_quarto_id;

  if v_anterior is not null and v_anterior <> p_quarto_id then
    update quartos set status = 'disponivel' where id = v_anterior;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. VISIBILIDADE PARA COMPRA EXTRA: so o pool avulso conta como "livre"
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW "gestao"."v_disponibilidade_quartos" AS
 SELECT q.evento_id,
    q.tipo,
    count(*) FILTER (WHERE (q.status = 'disponivel'::text) AND (q.finalidade = 'avulso'::text)
                      AND (NOT (EXISTS ( SELECT 1
             FROM gestao.reservas r
            WHERE ((r.quarto_id = q.id) AND (r.status <> 'cancelado'::text)))))) AS livres,
    count(*) AS total
   FROM gestao.quartos q
  GROUP BY q.evento_id, q.tipo;

alter view v_disponibilidade_quartos set (security_invoker = true);

-- ---------------------------------------------------------------------
-- 6. COMPRA AUTOMATICA DO PATROCINADOR SO PESCA DO POOL AVULSO
-- ---------------------------------------------------------------------
create or replace function patro_comprar_quarto(p_patrocinador_id uuid, p_tipo text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento  uuid;
  v_quarto  uuid;
  v_reserva uuid;
  v_seq     int;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  if p_tipo not in ('single','duplo','triplo') then
    raise exception 'Tipo de quarto invalido: %', p_tipo using errcode = '22023';
  end if;

  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;

  select q.id into v_quarto
  from quartos q
  where q.evento_id = v_evento
    and q.tipo = p_tipo
    and q.status = 'disponivel'
    and q.finalidade = 'avulso'
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
   where patrocinador_id = p_patrocinador_id and status <> 'cancelado';

  insert into reservas (evento_id, quarto_id, patrocinador_id, rotulo,
                        tipo, origem, status)
  values (v_evento, v_quarto, p_patrocinador_id,
          'Quarto ' || v_seq, p_tipo, 'extra', 'rascunho')
  returning id into v_reserva;

  perform _recalcular_fatura_patrocinador(p_patrocinador_id);

  return jsonb_build_object('ok', true, 'reserva_id', v_reserva, 'rotulo', 'Quarto ' || v_seq);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. COMPRA AUTOMATICA DO CIO VOLTA A EXISTIR — MESMO TEXTO DE ANTES DE
--    09/09, SO PESCANDO DO POOL AVULSO EM VEZ DE publico_alvo
-- ---------------------------------------------------------------------
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
    and q.finalidade = 'avulso'
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
returns table (reserva_id uuid, rotulo text, tipo text, origem text, status text,
               quarto_numero text, capacidade integer, ocupantes integer)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_part uuid;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;

  return query
    select r.id, r.rotulo, r.tipo, r.origem, r.status, q.numero,
           _capacidade_quarto(),
           (select count(*)::int from ocupantes o where o.reserva_id = r.id)
    from reservas r
    left join quartos q on q.id = r.quarto_id
    where r.participante_id = v_part and r.status <> 'cancelado'
    order by (r.origem = 'extra'), r.created_at;
end;
$$;

-- Preenche quem vai no quarto extra do CIO — nao existia antes: o CIO
-- podia comprar e cancelar mas nunca teve como dizer quem dormia la.
-- Mesmo padrao de patro_salvar_quarto/admin_salvar_ocupantes_equipe:
-- substitui a lista inteira, valida nome e o teto flat de
-- _capacidade_quarto() (regra do CIO, nao a fixa por tipo do
-- patrocinador).
create or replace function part_salvar_ocupantes_extra(
  p_reserva_id uuid,
  p_ocupantes jsonb,
  p_usa_transfer boolean default null,
  p_transfer_origem text default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_part uuid; v_origem text; v_cap int; v_qtd int; v_item jsonb; v_nasc date; v_limite date;
begin
  select participante_id, origem into v_part, v_origem
  from reservas where id = p_reserva_id and status <> 'cancelado';

  if v_part is null then
    raise exception 'Reserva nao encontrada' using errcode = 'P0002';
  end if;
  perform _exige_participante(v_part);

  if v_origem <> 'extra' then
    raise exception 'So quarto extra tem ocupantes preenchidos por aqui' using errcode = '42501';
  end if;

  v_cap := _capacidade_quarto();
  v_qtd := jsonb_array_length(coalesce(p_ocupantes, '[]'::jsonb));
  if v_qtd > v_cap then
    raise exception 'O quarto comporta % pessoa(s); voce enviou %.', v_cap, v_qtd
      using errcode = '22023';
  end if;

  perform _exige_origem_transfer(p_transfer_origem);

  select coalesce(e.data_inicio, current_date) into v_limite
  from reservas r join eventos e on e.id = r.evento_id
  where r.id = p_reserva_id;

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
    'ACOMPANHANTE'
  from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb)) x;

  update reservas set
    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),
    transfer_origem = coalesce(p_transfer_origem, transfer_origem),
    status          = case when v_qtd > 0 then 'completo' else 'rascunho' end
  where id = p_reserva_id;

  perform _recalcular_fatura_participante(v_part);

  return jsonb_build_object('ok', true, 'ocupantes', v_qtd, 'capacidade', v_cap);
end;
$$;

-- part_salvar_ocupantes_extra precisa ler quem ja esta la antes de
-- editar. patro_listar_ocupantes exige patrocinador (_exige_patrocinador)
-- e a reserva de quarto extra do CIO nao tem patrocinador_id — sem essa
-- versao, a tela nao consegue reabrir um quarto extra ja preenchido.
create or replace function part_listar_ocupantes_extra(p_reserva_id uuid)
returns table (
  ocupante_id uuid, nome text, cpf text, data_nascimento date, tipo text,
  usa_transfer boolean, transfer_origem text
) language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_part uuid; v_origem text;
begin
  select participante_id, origem into v_part, v_origem
  from reservas where id = p_reserva_id;
  perform _exige_participante(v_part);

  if v_origem <> 'extra' then
    raise exception 'So quarto extra tem ocupantes lidos por aqui' using errcode = '42501';
  end if;

  return query
    select o.id, o.nome, o.cpf, o.data_nascimento, o.tipo,
           o.usa_transfer, o.transfer_origem
    from ocupantes o
    where o.reserva_id = p_reserva_id
    order by o.created_at;
end;
$$;

create or replace function part_disponibilidade(p_evento_slug text)
returns table (tipo text, livres bigint, valor numeric)
language sql stable security definer
set search_path = gestao, public as $$
  select v.tipo, v.livres, _preco_item(e.id, 'quarto_' || v.tipo)
  from v_disponibilidade_quartos v
  join eventos e on e.id = v.evento_id
  where e.slug = p_evento_slug
  order by v.tipo;
$$;

revoke execute on function part_comprar_quarto(text, text) from public, anon;
revoke execute on function part_cancelar_quarto_extra(uuid) from public, anon;
revoke execute on function part_listar_meus_quartos(text) from public, anon;
revoke execute on function part_listar_ocupantes_extra(uuid) from public, anon;
revoke execute on function part_salvar_ocupantes_extra(uuid, jsonb, boolean, text) from public, anon;
revoke execute on function part_disponibilidade(text) from public, anon;
grant execute on function part_comprar_quarto(text, text) to authenticated, service_role;
grant execute on function part_cancelar_quarto_extra(uuid) to authenticated, service_role;
grant execute on function part_listar_meus_quartos(text) to authenticated, service_role;
grant execute on function part_listar_ocupantes_extra(uuid) to authenticated, service_role;
grant execute on function part_salvar_ocupantes_extra(uuid, jsonb, boolean, text) to authenticated, service_role;
grant execute on function part_disponibilidade(text) to authenticated, service_role;
