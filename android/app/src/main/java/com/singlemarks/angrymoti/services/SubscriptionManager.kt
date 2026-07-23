package com.singlemarks.angrymoti.services

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * 멤버십 구독 — Google Play Billing (iOS StoreKit 2 대응).
 * Play Console에 동일 상품 ID의 정기 결제를 등록해야 한다: com.timelock.pro.monthly / ₩4,400.
 */
object SubscriptionManager : PurchasesUpdatedListener {
    const val PRODUCT_ID = "com.timelock.pro.monthly"

    val isPro = MutableStateFlow(false)
    val product = MutableStateFlow<ProductDetails?>(null)

    /** 반대 플랫폼(iOS)에서 구독한 경우의 만료 시각(millis) — AccountStore 동기화가 채워준다.
     *  Pro 판정 = 이 기기 스토어 구독 ∨ 클라우드 기록이 아직 유효. */
    @Volatile private var cloudProUntil = 0L
    @Volatile private var storePro = false

    fun applyCloudPro(untilMillis: Long) {
        cloudProUntil = untilMillis
        recomputeIsPro()
    }

    private fun recomputeIsPro() {
        isPro.value = storePro || cloudProUntil > System.currentTimeMillis()
    }

    private var client: BillingClient? = null

    fun init(context: Context) {
        val c = BillingClient.newBuilder(context)
            .setListener(this)
            .enablePendingPurchases(
                PendingPurchasesParams.newBuilder().enableOneTimeProducts().build()
            )
            .build()
        client = c
        c.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    queryProduct(); refresh()
                }
            }
            override fun onBillingServiceDisconnected() {}
        })
    }

    private fun queryProduct() {
        val params = QueryProductDetailsParams.newBuilder()
            .setProductList(
                listOf(
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(PRODUCT_ID)
                        .setProductType(BillingClient.ProductType.SUBS)
                        .build()
                )
            ).build()
        client?.queryProductDetailsAsync(params) { result, list ->
            if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                product.value = list.firstOrNull()
            }
        }
    }

    fun refresh() {
        val params = QueryPurchasesParams.newBuilder()
            .setProductType(BillingClient.ProductType.SUBS).build()
        client?.queryPurchasesAsync(params) { result, purchases ->
            if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                val active = purchases.any {
                    it.purchaseState == Purchase.PurchaseState.PURCHASED &&
                        it.products.contains(PRODUCT_ID)
                }
                storePro = active
                recomputeIsPro()
                // 클라우드에 기록해 iOS 기기에서도 멤버십이 인정되게 한다
                // (Play Billing은 클라이언트에서 만료일을 못 얻으므로 월 구독+유예 35일로 추정 —
                //  구독 유지 중엔 앱을 열 때마다 앞으로 밀리고, 해지 후엔 자연 소멸)
                if (active) {
                    AccountStore.mirrorMembership(
                        System.currentTimeMillis() + 35L * 86_400_000L, "google")
                }
                purchases.filter { it.purchaseState == Purchase.PurchaseState.PURCHASED && !it.isAcknowledged }
                    .forEach(::acknowledge)
            }
        }
    }

    /** 무료 체험 phase(가격 0)를 포함한 오퍼를 우선 선택 — 없으면 첫 오퍼로 폴백.
     *  (Play Console에서 무료 체험을 등록하지 않으면 기존과 동일하게 첫 오퍼가 쓰인다) */
    private fun bestOffer(details: ProductDetails): ProductDetails.SubscriptionOfferDetails? {
        val offers = details.subscriptionOfferDetails ?: return null
        return offers.firstOrNull { offer ->
            offer.pricingPhases.pricingPhaseList.any { it.priceAmountMicros == 0L }
        } ?: offers.firstOrNull()
    }

    fun purchase(activity: Activity) {
        val details = product.value ?: return
        val offerToken = bestOffer(details)?.offerToken ?: return
        val flow = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(
                listOf(
                    BillingFlowParams.ProductDetailsParams.newBuilder()
                        .setProductDetails(details)
                        .setOfferToken(offerToken)
                        .build()
                )
            ).build()
        client?.launchBillingFlow(activity, flow)
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        if (result.responseCode == BillingClient.BillingResponseCode.OK && purchases != null) {
            purchases.filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }
                .forEach { p ->
                    if (!p.isAcknowledged) acknowledge(p)
                    if (p.products.contains(PRODUCT_ID)) {
                        storePro = true
                        recomputeIsPro()
                        AccountStore.mirrorMembership(
                            System.currentTimeMillis() + 35L * 86_400_000L, "google")
                    }
                }
        }
    }

    private fun acknowledge(p: Purchase) {
        client?.acknowledgePurchase(
            AcknowledgePurchaseParams.newBuilder().setPurchaseToken(p.purchaseToken).build()
        ) {}
    }

    /** 정기 결제가 — 무료 체험 오퍼일 때 첫 phase는 ₩0이므로, 가격이 있는 phase를 골라 표시한다 */
    val displayPrice: String
        get() {
            val details = product.value ?: return "₩4,400"
            val phases = bestOffer(details)?.pricingPhases?.pricingPhaseList ?: return "₩4,400"
            return phases.lastOrNull { it.priceAmountMicros > 0L }?.formattedPrice
                ?: phases.firstOrNull()?.formattedPrice ?: "₩4,400"
        }

    /** 무료 체험 문구("첫 14일 무료") — 무료 phase가 없으면 null → 페이월이 기존 문구로 폴백 */
    val freeTrialLabel: String?
        get() {
            val details = product.value ?: return null
            val trialPhase = bestOffer(details)?.pricingPhases?.pricingPhaseList
                ?.firstOrNull { it.priceAmountMicros == 0L } ?: return null
            return isoDurationToKorean(trialPhase.billingPeriod)?.let { "첫 $it 무료" }
        }

    /** ISO-8601 기간(P14D · P2W · P1M …)을 한국어로 — 파싱 실패 시 null */
    private fun isoDurationToKorean(period: String): String? {
        val m = Regex("""P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?""").matchEntire(period) ?: return null
        val (y, mo, w, d) = m.destructured
        return when {
            y.isNotEmpty()  -> "${y}년"
            mo.isNotEmpty() -> "${mo}개월"
            w.isNotEmpty()  -> "${w.toInt() * 7}일"
            d.isNotEmpty()  -> "${d}일"
            else -> null
        }
    }
}
