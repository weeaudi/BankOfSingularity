local ROOT = '/bank'
local original_package_path = package.path
package.path = ROOT .. '/server/?.lua;' .. ROOT .. '/server/?/init.lua;' ..
                   package.path

local cards = require('src.models.Card')

cards.issueCard({
    uid = '1',
    card_data = 'no data',
    account_id = 3,
    status = cards.CardStatus.Active
})

cards.issueCard({
    uid = '2',
    card_data = 'no data',
    account_id = 3,
    status = cards.CardStatus.Active
})

cards.issueCard({
    uid = '3',
    card_data = 'no data',
    account_id = 3,
    status = cards.CardStatus.Active
})

cards.issueCard({
    uid = '4',
    card_data = 'no data',
    account_id = 2,
    status = cards.CardStatus.Active
})

cards.setCardStatus('3', cards.CardStatus.Revoked)

local acct3Cards = cards.getCardsByAccountId(3)
for i = 1, #acct3Cards do print(acct3Cards[i].uid) end

print(cards.isUsable('3'))

package.path = original_package_path
