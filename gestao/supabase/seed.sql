-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- seed.sql  ·  dados minimos para o sistema abrir
--
-- Roda POR ULTIMO. E idempotente: rodar de novo nao duplica nada.
--
-- O que esta aqui e so o esqueleto - evento em rascunho, a ordem das
-- cotas e os tres itens de preco que a fatura le por nome. Numeros de
-- quarto, valores e patrocinadores entram pelo painel, nao por SQL.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. PRIMEIRO ADMIN
--
-- Sem esta linha ninguem consegue entrar no admin.html: is_admin() le a
-- tabela admins, e ela nasce vazia. TROQUE O E-MAIL pelo seu antes de
-- rodar - o magic link so chega em quem estiver aqui.
-- ---------------------------------------------------------------------
insert into admins (email, nome, role, ativo)
values ('gerardocarvalhogp@gmail.com', 'Gerardo Carvalho', 'admin', true)
on conflict (email_norm) do update
  set role = 'admin', ativo = true;

-- ---------------------------------------------------------------------
-- 2. EVENTO
--
-- Nasce em RASCUNHO de proposito: evento aberto ja aceita
-- auto-cadastro, e ninguem quer inscricao entrando antes das datas e
-- dos prazos estarem definidos. Ajuste tudo pelo painel (aba Estrutura)
-- e so entao mude o status para 'aberto'.
--
-- As datas ficam nulas porque nao devem ser adivinhadas aqui - a tela
-- de rooming usa prazo_contrato e prazo_rooming em texto para o
-- participante, e data errada e pior que data em branco.
-- ---------------------------------------------------------------------
insert into eventos (slug, nome, local, status, cota_unica)
values ('cerrado2027', 'CIO Cerrado Experience 2027',
        'Tauá Resort Alexânia', 'rascunho', false)
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------
-- 3. COTAS
--
-- A ordem_prioridade e o que define quem escolhe primeiro na mesa
-- redonda (1 escolhe antes de todos). A sequencia Esmeralda > Diamante
-- > Platina > Ouro > Prata e a regra de negocio herdada.
--
-- A composicao de quartos NAO entra aqui: ela vive em cota_quartos
-- (migracao-02) e depende do contrato daquela edicao. Chutar numeros
-- faria "Gerar quartos das cotas" criar reserva errada para 61
-- empresas. Preencha na aba Estrutura > Cotas antes de gerar.
-- ---------------------------------------------------------------------
insert into cotas (evento_id, nome, ordem_prioridade,
                   quartos_incluidos, vagas_mesa_redonda,
                   tem_reuniao_exclusiva, tem_jantar)
select e.id, c.nome, c.ordem, 0, c.mesa, c.reuniao, c.jantar
from eventos e
cross join (values
  ('Esmeralda', 1, 0, true,  true),
  ('Diamante',  2, 0, true,  true),
  ('Platina',   3, 0, false, true),
  ('Ouro',      4, 0, false, false),
  ('Prata',     5, 0, false, false)
) as c(nome, ordem, mesa, reuniao, jantar)
where e.slug = 'cerrado2027'
on conflict (evento_id, nome) do nothing;

-- ---------------------------------------------------------------------
-- 4. PRECOS
--
-- Estes tres itens sao lidos POR NOME no calculo da fatura
-- (_recalcular_fatura_participante / _recalcular_fatura_patrocinador,
-- em funcoes-financeiro.sql). Nascem em ZERO: assim a fatura ja
-- funciona, somando nada, e ninguem e cobrado por um valor de exemplo
-- que alguem esqueceu de trocar.
--
-- Para cobrar por faixa de idade, acrescente linhas do mesmo item com
-- idade_min/idade_max pela aba Precos. A linha sem faixa continua sendo
-- o fallback de quem nao informou data de nascimento.
-- ---------------------------------------------------------------------
insert into precos (evento_id, item, descricao, valor)
select e.id, p.item, p.descricao, 0
from eventos e
cross join (values
  ('acompanhante_adulto', 'Acompanhante adulto (hospedagem)'),
  ('crianca',             'Criança (hospedagem)'),
  ('transfer',            'Transfer por pessoa (GYN ou BSB)')
) as p(item, descricao)
where e.slug = 'cerrado2027'
on conflict (evento_id, item, coalesce(idade_min,-1), coalesce(idade_max,999))
do nothing;

-- Quarto extra comprado pelo portal do patrocinador. Sem estes itens a
-- compra funciona, mas entra na fatura valendo zero.
insert into precos (evento_id, item, descricao, valor)
select e.id, p.item, p.descricao, 0
from eventos e
cross join (values
  ('quarto_single', 'Quarto single extra'),
  ('quarto_duplo',  'Quarto duplo extra'),
  ('quarto_triplo', 'Quarto triplo extra')
) as p(item, descricao)
where e.slug = 'cerrado2027'
on conflict (evento_id, item, coalesce(idade_min,-1), coalesce(idade_max,999))
do nothing;

-- ---------------------------------------------------------------------
-- 5. CONFERENCIA
--
-- Rode isto depois. Se alguma linha vier zerada, o passo anterior nao
-- pegou - quase sempre porque o slug do evento foi trocado acima e as
-- outras insercoes continuaram procurando 'cerrado2027'.
-- ---------------------------------------------------------------------
do $$
declare
  v_ev int; v_cotas int; v_precos int; v_admins int;
begin
  select count(*) into v_ev     from eventos where slug = 'cerrado2027';
  select count(*) into v_cotas  from cotas c join eventos e on e.id = c.evento_id
                                where e.slug = 'cerrado2027';
  select count(*) into v_precos from precos p join eventos e on e.id = p.evento_id
                                where e.slug = 'cerrado2027';
  select count(*) into v_admins from admins where role = 'admin' and ativo;

  raise notice 'evento: %  cotas: %  precos: %  admins ativos: %',
    v_ev, v_cotas, v_precos, v_admins;

  if v_admins = 0 then
    raise warning 'Nenhum admin ativo: ninguem conseguira entrar no admin.html.';
  end if;
end $$;
