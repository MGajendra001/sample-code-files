class Brand::Subscription < ProductSubscription
  CUSTOM_ANNUAL_PLAN = 'brand_custom_annual'.freeze
  CUSTOM_MONTHLY_PLAN = 'brand_custom_monthly'.freeze

  has_one :campaign, dependent: :destroy, class_name: 'Brand::Campaign', foreign_key: 'post_subscription_id'

  state_machine :state, initial: :draft do
    event :activate do
      transition [:draft] => :needs_markup
    end
    event :set_markup do
      transition [:needs_markup] => :needs_order
    end
    event :set_order do
      transition [:needs_order] => :payment_needed
    end
    event :set_payment do
      transition [:payment_needed] => :needs_submission
    end
    event :set_order do
      transition [:needs_submission, :submission_failed] => :active
    end
    event :set_submission_failure do
      transition [:needs_submission] => :submission_failed
    end
    event :reset_submission do
      transition [:submission_failed] => :needs_submission
    end
    event :cancel do
      transition [:active] => :cancelled
    end
    event :reactivate do
      transition [:cancelled] => :active
    end

    after_transition on: [:set_payment],
                     do: [:create_on_stripe, :set_subscription_dates, :create_order, :create_bundled_orders]
    after_transition on: [:cancel],
                     do: [:cancel_stripe_subscription, :send_cancelation_email, :cancel_order,
                          :set_canceled_at,]
    after_transition on: [:reset_submission], do: [:create_order]
  end

  def custom_annual_plan
    CUSTOM_ANNUAL_PLAN
  end

  def custom_monthly_plan
    CUSTOM_MONTHLY_PLAN
  end

  def create_order
    Brand::CampaignCreateService.process!(campaign: campaign)
  end

  def create_bundled_orders
    Brand::GbpOptimizationCreateService.process!(campaign: campaign)
    return unless includes_gbp_and_website_optimization?

    Brand::WebsiteOptimizationCreateService.process!(campaign: campaign)
  end

  def cancel_order
    campaign.cancel! if campaign.active?
  end

  def payment_description
    'Google post'
  end

  def needs_order?
    state == 'needs_order'
  end

  def supports_tier_change?
    false
  end

  def change_tier; end

  def includes_gbp_and_website_optimization?
    product_tier.title == 'Includes google post and website optimization'
  end
end
