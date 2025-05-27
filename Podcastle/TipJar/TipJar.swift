//
//  TipJar.swift
//  Podcastle
//
//  Created by Emídio Cunha on 15/05/2025.
//
//  MIT License
//
//  Copyright (c) 2025 Emídio Cunha
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import StoreKit

@MainActor class TipJar: ObservableObject {
    @Published var isPurchased: Bool = false
    @Published var product: Product?

    // Change this to your actual product ID
    private let productID = "tipjar"

    init() {
        Task {
            await loadProduct()
            await checkIfPurchased()
        }
    }

    /// Loads the product metadata from the App Store
    func loadProduct() async {
        do {
            let storeProducts = try await Product.products(for: [productID])
            product = storeProducts.first
        } catch {
            print("❌ Failed to load product: \(error)")
        }
    }

    /// Attempts to purchase the tip product
    func purchase() async {
        guard let product = product else {
            print("⚠️ Product not loaded yet")
            return
        }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    isPurchased = true
                    print("✅ Purchase successful")
                case .unverified(_, let error):
                    print("❌ Unverified transaction: \(error)")
                }
            case .userCancelled:
                print("ℹ️ Purchase cancelled")
            case .pending:
                print("ℹ️ Purchase pending approval")
            @unknown default:
                print("❓ Unknown purchase result")
            }

        } catch {
            print("❌ Purchase failed: \(error)")
        }
    }

    /// Checks if the tip has already been purchased
    func checkIfPurchased() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == productID {
                isPurchased = true
                return
            }
        }

        isPurchased = false
    }
}
