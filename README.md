# AH Crafter Price

Addon para WoW Retail que estima custo de craft e margem de venda usando precos da Casa de Leiloes (AH).

## O que ele mostra
- Custo total dos reagentes da receita.
- Valor estimado do item craftado na AH.
- Lucro ou perda provavel (`valor do item - custo de craft`).
- Detalhe por reagente logo abaixo do resumo.
- Progresso da busca em tempo real (ex.: reagentes consultados na AH).
- Lista de reagentes em ordem alfabetica para leitura consistente.

No painel de profissao, os 3 valores principais ficam destacados:
- `Gasto crafting`
- `Valor item AH`
- `Lucro provavel` ou `Perda provavel`

## Instalacao
1. Coloque a pasta `AHCrafterPrice` em `Interface/AddOns`.
2. Abra o jogo e confirme que o addon esta habilitado.
3. Recarregue a UI (`/reload`) se necessario.

## Uso rapido
1. Abra a janela de Profissao e selecione uma receita.
2. Abra a Casa de Leiloes para buscar precos ao vivo.
3. Use `/craftprice panel` para exibir/ocultar o painel.
4. Arraste o painel para onde preferir na tela (a posicao fica salva).

Se a AH estiver fechada, o addon usa cache local e avisa quando a estimativa esta parcial ou com dados antigos.

## Comandos
- `/craftprice help`
- `/craftprice ui`
- `/craftprice panel`
- `/craftprice panel reset` (reseta a posicao do painel de profissao)
- `/craftprice scan <receita>`
- `/craftprice scanall`
- `/craftprice minimap show`
- `/craftprice minimap hide`
- `/craftprice cache stats`
- `/craftprice cache clear`

## Como adicionar receitas estaticas
Edite `AHCrafterPrice.lua` e adicione entradas em `recipes`:

```lua
recipes["nome da receita"] = {
    itemName = "nome do item craftado",
    reagents = {
        ["nome do reagente 1"] = quantidade,
        ["nome do reagente 2"] = quantidade,
    },
}
```

## Observacoes
- O addon tenta usar a API de leilao adequada para Retail.
- Resultados dependem dos dados disponiveis na AH e no cache.
- Quando faltam precos de reagentes ou do item final, a margem pode ficar parcial.
