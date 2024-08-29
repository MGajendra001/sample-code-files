class PostSubscription < ApplicationRecord
  acts_as_paranoid
  belongs_to :subscriber, polymorphic: true
  belongs_to :product
  belongs_to :product_tier
  belongs_to :payment_source

  has_one :order_purchase, as: :purchasable, class_name: 'OrderPurchase'
  has_one :vendor_quote, through: :order_purchase

  before_destroy :check_for_active_subscription, prepend: true

  audited

  enum cycle_type: %i[yearly monthly monthly_commitment]

  attr_accessor :admin_destroy, :extra_data

  before_update :set_markup_total, :change_tier, if: -> {
    product_tier_id_changed? && product_tier_id.present? && markup.present?
  }
  after_commit :setup_generic_payment_form, :change_contact_status, on: :create

  scope :activated, -> { where(state: :active) }
  scope :inactive, -> { where.not(state: :active) }
  scope :for_end_users, -> { where(subscriber_type: 'Contact') }
  scope :up_for_renewal, ->(date) { where('renewal_date < ?', date) }
  scope :past_trial, -> { where(type: 'Zipwhip::Subscription').where(state: :cancelled) }

  RENEWAL_THRESHOLD = 14.days.freeze
  DEFAULT_TRIAL_DAYS = 10

  def set_markup_total
    markup.update(total: wholesale_price * (100 + markup.percentage) / 100)
    update_markup
  end

  def create_on_stripe
    create_stripe_subscription(product_tier.stripe_yearly_plan_id) if yearly? && product_tier.yearly_cost.to_i > 0
    create_stripe_subscription(product_tier.stripe_monthly_plan_id) if monthly? && product_tier.cost.to_i > 0
    create_stripe_subscription(product_tier.stripe_monthly_plan_id) if monthly_commitment? && product_tier.cost.to_i > 0
  end

  def create_stripe_subscription(stripe_id)

    sub = Stripe::Subscription.create(
      customer: payment_source.stripe_id,
      items: [
        {
          plan: stripe_id,
        },
      ],
      metadata: stripe_metadata
    )
    raise Errors::StripeIncompleteSubscriptionError if sub.status == 'incomplete'

    self.stripe_subscription_id = sub.id
    self.price = product_tier.yearly_cost.to_i if yearly?
    self.price = product_tier.cost.to_i if monthly?
    save
  end

  def update_payment_source
    return unless @subscription.stripe_subscription_id?

    stripe_sub = Stripe::Subscription.retrieve(@subscription.stripe_subscription_id)
    stripe_sub.default_source = new_source.id
  end

  def set_subscription_dates
    self.activation_date = Time.now
    self.renewal_date = monthly? ? Time.now + 1.month : Time.now + 1.year
    save
  end

  def cancel_stripe_subscription
    return unless stripe_subscription_id.present?

    stripe_sub = Stripe::Subscription.retrieve(stripe_subscription_id)
    stripe_sub.delete if stripe_sub && stripe_sub.status != 'canceled'
  end

  # trial related
  # can be overridden by sub classes
  def supports_trial?
    false
  end

  def trial_days
    DEFAULT_TRIAL_DAYS
  end

  def remaining_trial_days
    return 0 if trial_ends_at.nil?

    days = ((trial_ends_at - Time.zone.now).to_i / 1.day.to_f).ceil
    days < 0 ? 0 : days
  end

  def trial_active?
    remaining_trial_days > 0
  end

  def send_cancelation_email
    ProductSubscriptionMailer.internal_cancelation_notification_email(self).deliver_later

    return unless vendor_order&.cancelation_support_email.present?

    VendorMailer.subscription_cancelled_email(self).deliver_later
  end

  def set_canceled_at
    update(canceled_at: DateTime.now)
  end

  def display_price
    return markup.total * markup_multiplier if markup.present? && (markup.total.to_f > 0 || is_a?(Yext::Subscription))

    if price.nil?
      return product_tier.yearly_cost.to_i / 100 if yearly?
      return product_tier.cost.to_i / 100 if monthly?
    else
      price / 100
    end
  end

  def markup_success_fee
    markup.success_fee if markup.present? && markup.success_fee > 0
  end

  def wholesale_price
    return 0 if product_tier.nil?

    if is_a?(Yext::Subscription) && subscriber.is_a?(Contact) &&
       subscriber.eligible_for_promotion(Promotion::Kind::YEXT_XMAS_2019)
      index = product.product_tiers.wholesale.pluck(:id).index(product_tier.id)
      if index == 0 && subscriber.user.remaining_free_yext_subscriptions > 0
        0
      else
        return Promotion.yext_promotional_pricing[index][0] if monthly?
        return Promotion.yext_promotional_pricing[index][1] if yearly?
      end
    elsif is_a?(AdviceLocal::Subscription) && subscriber.is_a?(Contact) &&
          subscriber.eligible_for_promotion(Promotion::Kind::ADVICE_LOCAL_BUNDLE) &&
          subscriber.user.remaining_free_advice_local_subscriptions > 0
      0
    else
      return product_tier.yearly_cost.to_i / 100 if yearly?
      return product_tier.cost.to_i / 100 if monthly?
    end
  end

  def needs_order?
    false # this should be overriden by sub-classes
  end

  def about_to_expire?
    renewal_date&.future? && (renewal_date.to_time.to_i - Date.today.to_time.to_i < RENEWAL_THRESHOLD)
  end

  def setup_generic_payment_form
    FormHash.create(form_owner: self, kind: FormHash::Kind::PRODUCT_SUBSCRIPTION_PAYMENT_SOURCE)
  end

  def change_contact_status
    return unless subscriber.is_a?(Contact)

    subscriber.try(:activate_to_client)
  end

  def charge_one_time_fee_on_stripe_if_needed
    return unless charge_one_time_fee

    fee = markup.present? ? (markup.setup_fee || 0) * 100 : product.one_time_fee

    # Do not create stripe invoice if fee is zero
    return if fee.zero?

    Stripe::InvoiceItem.create(
      customer: payment_source.try(:stripe_id),
      amount: fee,
      currency: 'usd',
      description: product.one_time_fee_description
    )
  end

  def payment_form_hash
    if form_hash.nil?
      FormHash.create(form_owner: self, kind: FormHash::Kind::PRODUCT_SUBSCRIPTION_PAYMENT_SOURCE)
    else
      form_hash
    end
  end

  def send_external_payment_notification
    ProductSubscriptionMailer.external_payment_notification_email(self).deliver_later
  end

  def payment_description
    # legacy
    'Reputation management and business profile distribution services.'
  end

  def comped?
    subscriber_type == 'Subscription' && type == 'Mono::Subscription' &&
      subscriber && renewal_date == (subscriber.created_at.to_date + 1.year)
  end

  # DO NOT USE THIS METHOD
  def stripe_sources
    return [] unless payment_source&.stripe_id

    current_stripe_id = payment_source.stripe_id
    current_stripe_source_id = payment_source.stripe_source_id
    customer = Stripe::Customer.retrieve(current_stripe_id)
    source_ids = customer.sources.map(&:id) - [current_stripe_source_id]
    PaymentSource.where(stripe_source_id: source_ids).all
  end

  def user
    subscriber.is_a?(User) ? subscriber : subscriber&.user
  end

  def notification_email
    payment_source.email
  end

  def member_payout
    if markup.present? && markup.total.to_i > 0
      markup.total - wholesale_price
    else
      0
    end
  end

  def setup_fee_member_payout
    if markup.present? && markup.setup_fee.to_i > 0
      markup.setup_fee - setup_fee_wholesale_price
    else
      0
    end
  end

  def setup_fee_wholesale_price
    if product_tier.present? && product_tier.setup_fee.to_i > 0
      product_tier.setup_fee / 100
    elsif product.present? && product.one_time_fee.to_i > 0
      product.one_time_fee / 100
    else
      0
    end
  end

  def supports_tier_change?
    false
  end

  def change_tier
    true
  end

  def vendor_order
    return nil unless respond_to?(:order)

    order.respond_to?(:vendor_order) ? order.vendor_order : nil
  end

  def stripe_metadata
    Stripe::MetadataBuilder.process!(self)
  end

  private

  def check_for_active_subscription
    if invoices.present?
      errors[:base] << 'cannot delete a subscription with invoice'
      throw(:abort)
    elsif state.eql?('active')
      errors[:base] << 'cannot delete an active subscription'
      throw(:abort)
    end
  end
end
