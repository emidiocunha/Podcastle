//
//  InAppPurchase.swift
//  Podcastle
//
//  Created by Emídio Cunha on 20/11/2023.
//
//

import Foundation
import UIKit
import StoreKit

extension Notification.Name {
    static let unlockNotification = Notification.Name("UnlockNotification")
}

class InAppPurchase: NSObject, SKProductsRequestDelegate, SKPaymentTransactionObserver, UIAlertViewDelegate, ObservableObject  {
    var products:SKProductsRequest?
    var unlock:SKProduct?
    static let shared = InAppPurchase()
    var displayMessage:(String) -> Void = {_ in }
    
    public func unlocked() -> Bool {
        var u = UserDefaults.standard.bool(forKey: "unlocked")
    //#if targetEnvironment(simulator)
    //    u = false
    //#endif
        return u
    }
    
    public func start(finish: @escaping (String) -> Void) {
        products = SKProductsRequest(productIdentifiers: Set(arrayLiteral: "Podcastle_Unlock"))
        products?.delegate = self
        products?.start()
        displayMessage = finish
    }
    
    public func restore() {
        SKPaymentQueue.default().remove(self)
        SKPaymentQueue.default().add(self)
        SKPaymentQueue.default().restoreCompletedTransactions()
    }
    
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        let p = SKPayment(product: response.products.first!)
        
        SKPaymentQueue.default().add(p)
        SKPaymentQueue.default().remove(self)
        SKPaymentQueue.default().add(self)
    }
    
    func request(_ request: SKRequest, didFailWithError error: Error) {
        NSLog("Failed to get product list")
    }
    
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for t in transactions {
            switch t.transactionState {
            case .purchased:
                completeTransaction(t)
            case .restored:
                restoreTransaction(t)
            default:
                failedTransaction(t)
            }
        }
    }
    
    func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
        if queue.transactions.count > 0 {
            let u = UserDefaults.standard
            
            u.set(true, forKey: "unlocked")
            NotificationCenter.default.post(name: Notification.Name.unlockNotification, object:nil)
        }
    }
    
    func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: Error) {
        displayMessage("There was a problem, please try again later.\nRestore Purchase Not Possible")
    }
    
    func completeTransaction(_ t:SKPaymentTransaction) {
        let u = UserDefaults.standard
        
        u.set(true, forKey: "unlocked")
        SKPaymentQueue.default().finishTransaction(t)
        NotificationCenter.default.post(name: Notification.Name.unlockNotification, object:nil)
    }
    
    func failedTransaction(_ t:SKPaymentTransaction) {
        if t.error != nil {
            if t.error!._code != SKError.paymentCancelled.rawValue {
                displayMessage("There was a problem, please try again later.\nRestore Purchase Not Possible")
            }
        }
        SKPaymentQueue.default().finishTransaction(t)
    }
    
    func restoreTransaction(_ t:SKPaymentTransaction) {
        SKPaymentQueue.default().finishTransaction(t)
        NotificationCenter.default.post(name: Notification.Name.unlockNotification, object:nil)
    }
    
    /*func displayMessage(_ message:String, title:String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let ok = UIAlertAction(title: "OK", style: .default)
        let viewController = UIApplication.shared.windows.first!.rootViewController!
        
        alert.addAction(ok)
        if let p = alert.popoverPresentationController {
            p.sourceView = viewController.view
            p.sourceItem = viewController.toolbarItems?.first
        }
        
        viewController.present(alert, animated: true)
    }*/
}
