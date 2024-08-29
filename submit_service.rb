class Post::SubmitService
  APPROVAL_URL = 'https://posts/api/campaign/workflow'.freeze
  APP_SECRET = ENV.fetch('APP_SECRET', nil)

  include HTTParty

  def self.process!(campaign:)
    new(campaign).process
  end

  def initialize(campaign)
    @campaign = campaign
  end

  def process
    self.class.post(APPROVAL_URL, body: params, headers: headers)
    @campaign.acknowledge_submission
  end

  private

  def params
    {
      campaignCode: @campaign.campaign_code,
      customerId: @campaign.customer_id,
    }
  end

  def headers
    {
      'app-secret': APP_SECRET,
    }
  end
end
