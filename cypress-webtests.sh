#!/bin/bash
# =============================================================================
# Script Name: cypress-tests.sh
# Description: This script is an E2E test script using cypress.
# Author: Noriaki Mushino
# Date Created: 2025-05-29
# Last Modified: 2025-05-29
# Version: 1.0
#
# Prerequisites:
#   - cypress command is required 
#   - The Test was conducted on MacOS
#
# =============================================================================
# 実行にはnpm install --save-dev cypressによる node_modules が必須です。

cd tests
# Cypress テスト droneshop.cy.js を実行
npx cypress run --spec "cypress/e2e/droneshop.cy.js"
