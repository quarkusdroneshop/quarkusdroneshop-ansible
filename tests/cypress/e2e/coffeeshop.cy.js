import '@testing-library/cypress/add-commands'

describe('template spec', () => {
  it('passes', () => {
    // Webにアクセス
    cy.visit("http://quarkusdroneshop-web-quarkusdroneshop-demo.apps.cluster-gkc2p.gkc2p.sandbox1535.opentlc.com/")

    // メニューボタンをクリック
    cy.get("section:nth-child(8)>div:nth-child(1)>div:nth-child(3)>div:nth-child(1)")
    .should('be.visible')
    .click()

    // モーダル画面で注文処理の実行/Coffee (black)
    cy.get("div:nth-child(1)>div:nth-child(1)>div:nth-child(1)>div:nth-child(2)>button:nth-child(1)").click()
    cy.findByLabelText("for Name:", {"selector":"input","trim":true}).click()
    cy.findByLabelText("for Name:", {"selector":"input","trim":true}).type("Noriaki Mushino")
    cy.get("button:nth-child(7)").click()
    cy.findByRole("button",{"name":"Place Order"}).click()

    // モーダル画面で注文処理の実行/Coffee (with room)
    cy.get("div:nth-child(1)>div:nth-child(2)>div:nth-child(1)>div:nth-child(2)>button:nth-child(1)").click()
    cy.findByLabelText("for Name:", {"selector":"input","trim":true}).click()
    cy.get("button:nth-child(7)").click()
    cy.findByRole("button",{"name":"Place Order"}).click()

    // モーダル画面で注文処理の実行/Espresso
    cy.get("div:nth-child(1)>div:nth-child(3)>div:nth-child(1)>div:nth-child(2)>button:nth-child(1)").click()
    cy.findByLabelText("for Name:", {"selector":"input","trim":true}).click()
    cy.get("button:nth-child(7)").click()
    cy.findByRole("button",{"name":"Place Order"}).click()

    // モーダル画面で注文処理の実行/Espresso (Double) 
    cy.get("div:nth-child(1)>div:nth-child(4)>div:nth-child(1)>div:nth-child(2)>button:nth-child(1)").click()
    cy.findByLabelText("for Name:", {"selector":"input","trim":true}).click()
    cy.get("button:nth-child(7)").click()
    cy.findByRole("button",{"name":"Place Order"}).click()

    // モーダル画面で注文処理の実行/Cappuccino
    cy.get("div:nth-child(1)>div:nth-child(5)>div:nth-child(1)>div:nth-child(2)>button:nth-child(1)").click()
    cy.findByLabelText("for Name:", {"selector":"input","trim":true}).click()
    cy.get("button:nth-child(7)").click()
    cy.findByRole("button",{"name":"Place Order"}).click()

    // モーダル画面で注文処理の実行/Croissant
    cy.get("div:nth-child(2)>div:nth-child(1)>div:nth-child(1)>div:nth-child(2)>button:nth-child(1)").click()
    cy.findByLabelText("for Name:", {"selector":"input","trim":true}).click()
    cy.get("button:nth-child(7)").click()
    cy.findByRole("button",{"name":"Place Order"}).click()

    // モーダル画面で注文処理の実行/Chocolate Croissant
    cy.get("div:nth-child(2)>div:nth-child(2)>div:nth-child(1)>div:nth-child(2)>button:nth-child(1)").click()
    cy.findByLabelText("for Name:", {"selector":"input","trim":true}).click()
    cy.get("button:nth-child(7)").click()
    cy.findByRole("button",{"name":"Place Order"}).click()

    // モーダル画面で注文処理の実行/Muffin
    cy.get("div:nth-child(2)>div:nth-child(3)>div:nth-child(1)>div:nth-child(2)>button:nth-child(1)").click()
    cy.findByLabelText("for Name:", {"selector":"input","trim":true}).click()
    cy.get("button:nth-child(7)").click()
    cy.findByRole("button",{"name":"Place Order"}).click()

    // モーダル画面で注文処理の実行/Cakepop
    cy.get("div:nth-child(2)>div:nth-child(4)>div:nth-child(1)>div:nth-child(2)>button:nth-child(1)").click()
    cy.findByLabelText("for Name:", {"selector":"input","trim":true}).click()
    cy.get("button:nth-child(7)").click()
    cy.findByRole("button",{"name":"Place Order"}).click()

  })
})