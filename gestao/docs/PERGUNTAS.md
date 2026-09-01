# Perguntas para o organizador

Todos os "A confirmar" dos 11 arquivos de área, consolidados aqui para
responder de uma vez. Organizado por assunto, com o arquivo de origem entre
colchetes.

Perguntas que o código já respondeu **não estão aqui** — foram direto para o
arquivo de área correspondente, como fato conferido.

---

## Visão geral e papéis

1. Comportamento de sessão expirada: o usuário perde o que estava digitando?
   `[00, 30]`
2. A tabela `auditoria` existe no schema, mas só uma função grava nela hoje
   e está vazia em produção. É para expandir, ou é vestígio de uma ideia que
   não avançou? `[00, 70]`
3. A lista de eventos do admin esconde `status='encerrado'` por padrão, ou
   mostra tudo permanentemente? `[00]`
4. Papéis existentes são exatamente quatro, ou há nível intermediário? A
   distância medida entre admin e staff (81 de 111 funções exigem admin
   especificamente, inclusive para listar) é a intenção, ou staff deveria
   enxergar mais do que enxerga hoje? `[00, 10, 70]`
5. Como o sistema trata edição concorrente do mesmo registro por duas
   pessoas ao mesmo tempo — por exemplo, dois usuários do mesmo
   patrocinador editando a mesma aba? `[00]`
6. A experiência real do staff ao clicar numa aba admin-only
   (Cadastro, Estrutura, Patrocinadores, Preços, Financeiro, Pesquisa) é um
   erro visível, ou há tratamento mais cuidadoso na tela que o código só não
   deixa claro? `[10]`

## Schema e dados

7. O que exatamente é `participante_perfil` e qual tela usa esses campos?
   `[70]`
8. Há campo de sobrescrita manual em `contratos` para assinatura fora do
   fluxo do Autentique? Não encontrado no schema — se existe, é fora da
   tabela. `[70]`
9. Alcance de staff sobre dado financeiro de patrocinador fora do evento
   associado a ele em `admin_eventos` — hoje o bypass de staff em
   `pode_ver_patrocinador` não distingue evento. `[70]`
10. O patrocinador deveria ter acesso a eventos passados? Hoje
    `meus_patrocinadores()` não filtra por evento nem por status. `[70]`

## Admin (`admin.html`)

11. As 26 funções `admin_*` cujo mecanismo de guarda não bateu com o padrão
    de busca desta apuração — conferir uma a uma se têm proteção adequada.
    `[10]`
12. Escopo exato de `admin_match_jantar` — é a ponte entre a aba Sessões e o
    módulo `jantares.html`? `[10]`
13. Natureza e origem do módulo Pesquisa de perfil — de onde vêm as
    respostas importadas (Sympla, formulário próprio, outro canal)? Não
    estava em nenhum dos 11 arquivos originais. `[10]`
14. Indicadores exatos do Painel (Visão geral) e se são clicáveis para a
    lista detalhada. `[10]`
15. Lista completa de exportações do admin e o formato exato de cada uma —
    não conferido arquivo por arquivo, só o código que as gera. `[10]`
16. Se o modal de cobrança da aba Acompanhamento deveria ter modelos salvos
    e reutilizáveis, em vez de rascunho editável a cada envio. `[10, 60]`
17. `admin_gerar_sessoes` aparece na aba Brindes — é atalho para gerar sessão
    de mesa redonda a partir dali, ou item não relacionado ao brinde? `[10]`

## Portal do patrocinador (`portal.html`)

18. Em que momento a lista final de mesa redonda é considerada "liberada"
    para o patrocinador ver o resultado — não encontrado um estado explícito
    de "lista fechada" na aba Mesa redonda. `[20]`
19. Existe prazo de corte por aba além do prazo de fila da mesa redonda? Não
    encontrado bloqueio geral de edição por data nas demais abas. `[20]`
20. O patrocinador consegue exportar a própria lista de participantes? Não
    encontrada nenhuma chamada de exportação em `portal.html`. `[20]`
21. Existe registro visível na tela (não só no banco) de quando cada dado
    foi salvo e por qual usuário, quando há mais de um login na mesma
    empresa? `[20]`
22. Onde a cota em si é paga/registrada — a aba Financeiro do portal cobre
    só adicionais (quarto extra, brinde no quarto), não o valor da cota.
    `[20]`

## Área do CIO (`rooming.html`)

23. A regra de check-in/check-out com "noite extra" descrita no rascunho
    original não foi encontrada no código — existe em algum outro lugar, ou
    era um plano que não foi construído dessa forma? `[30, DIVERGENCIAS #10]`
24. Há prazo de corte separado para alterar rooming depois de já preenchido
    uma vez, além do prazo geral do evento? `[30]`
25. Como o CIO pede algo fora do padrão (chegada antecipada, pedido
    especial) — não encontrado campo de observação livre em `rooming.html`.
    `[30]`
26. Valores atuais de acompanhante, criança por faixa de idade, e se existe
    de fato cobrança de "noite extra". `[30]`
27. O pagamento da fatura do CIO acontece pelo sistema ou fora dele? Não
    encontrado RPC de pagamento nem gateway integrado. `[30]`

## Check-in (`checkin.html`)

28. A tela cruza pendência financeira/de contrato no momento do check-in, ou
    mostra só identificação e categoria de crachá? `[40]`
29. Comportamento com internet instável — não encontrada fila local nem
    retry no código. `[40]`
30. O que a tela mostra, especificamente, para acompanhante e para criança —
    não conferida a renderização linha a linha. `[40]`
31. O QR do crachá é de fato opaco (sem dado exposto no impresso)? Não
    verificado o formato do conteúdo codificado nem o gerador do crachá.
    `[40]`
32. O leitor de QR de `checkin.html` (chegada geral) e o check-in por
    atividade de `admin.html` deveriam compartilhar o mesmo componente de
    leitura? Hoje não confirmei se já compartilham. `[40, 60]`

## Jantares (`jantares.html`)

33. A etapa de "validação com o patrocinador" com lista sem nome de
    executivo — ainda existe no processo? Se sim, por qual caminho, já que
    não está em `jantares.html`? `[50, DIVERGENCIAS #11]`
34. A confirmação de presença do convidado de jantar é por link, e-mail ou
    Sympla? O campo `sympla_url` existe por jantar, mas não encontrei o
    texto/canal de convite em si no código lido. `[50]`
35. Vale importar o histórico de 44 jantares da planilha antiga para dentro
    do schema `gestao`, para a aba Estatísticas enxergar o padrão completo?
    Decisão represada desde 2026-08-31 — envolve casar ~900 pessoas contra o
    cadastro atual. `[50]`

## Módulos previstos (`60-modulos-previstos.md`)

36. Andamento da verificação da conta WhatsApp Business — dependência
    externa com prazo próprio, não rastreável pelo código. `[60]`
37. Há qualquer sinalização recente do parceiro do app do evento sobre
    construir uma API? Se não, não há necessidade de revisitar isso tão
    cedo. `[60]`

## Integrações (`80-integracoes.md`)

38. Frequência real de execução do `integracao.py` no Agendador de Tarefas —
    não documentada em nenhum lugar do repositório de código. `[80]`
39. Onde ficam as variáveis de ambiente e quem tem acesso a elas — parte
    está no Agendador de Tarefas (máquina local), parte em secrets do
    Supabase; não há um único lugar. `[80]`
40. Rotina de backup do schema `gestao` e responsável por ela. `[80]`
41. O domínio `ciocerrado.com.br` já foi verificado no Resend (SPF/DKIM)?
    Enquanto não estiver, o envio pela tela continua falhando com 403 para
    qualquer destinatário fora da conta de testes — e, quando for
    verificado, o botão de envio na tela passa a disparar de verdade sem
    aviso extra (ver `DIVERGENCIAS.md`, item 4). `[80]`
42. Tempo de validade do magic link e da sessão — não é parametrizado no
    schema `gestao`, é configuração do Supabase Auth fora deste repositório.
    `[80]`
43. Existe ambiente de preview/staging separado da produção, ou o evento de
    teste dentro da produção faz esse papel? `[80]`
