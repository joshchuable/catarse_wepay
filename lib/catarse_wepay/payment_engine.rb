module CatarseWepay
  class PaymentEngine

    def name
      'Wepay'
    end

    def review_path contribution
      CatarseWepay::Engine.routes.url_helpers.review_wepay_path(contribution)
    end

    def can_do_refund?
      true
    end

    def direct_refund contribution
      CatarseWepay::ContributionActions.new(contribution).refund
    end

    def locale
      'en'
    end

  end
end
