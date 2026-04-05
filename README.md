# AH Crafter Price

Addon inicial para WoW Retail que calcula o custo de reagentes e preço do item craftado na Casa de Leilões.

## Uso
1. Coloque a pasta `AHCrafterPrice` em sua pasta `Interface/AddOns`.
2. Abra o jogo e certifique-se de que o addon está ativado.
3. Abra a Casa de Leilões.
4. No chat, execute:
   `/craftprice scan mochila de seda de fogo solar`
5. Para escanear todas as receitas conhecidas no ofício de alfaiataria, abra a janela de Ofício/Profissão e execute:
   `/craftprice scanall`

## Como adicionar receitas
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

## Observações
- Este addon usa a API clássica de leilão `QueryAuctionItems`.
- Se você estiver em Retail ou em outra versão do WoW, a API de leilões pode ser diferente.
- A ideia é mostrar o custo total dos reagentes e uma estimativa de margem de lucro.
