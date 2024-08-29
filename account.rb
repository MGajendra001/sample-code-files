class Account < ApplicationRecord
  has_one_attached :logo
  has_many :users, dependent: :destroy
  
  validates :name, presence: true
  validates :subdomain, presence: true, uniqueness: true, exclusion: { in: %w(www api admin),
    message: "%{value} is reserved." }

  attr_accessor :new_admin_email

  before_validation :setup_admin_user, if: -> { new_admin_email.present? }
  
  def self.ransackable_attributes(auth_object = nil)
    ["name", "subdomain"]
  end

  def setup_admin_user
    user = User.find_by(email: new_admin_email)
    if user
      errors.add(:new_admin_email, 'This email is already registered to another benefits hub account.')
    else
      users.new(email: new_admin_email, onboarded: true, role: :admin)
    end
  end

end
